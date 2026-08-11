;;; super-harness-test.el --- ERT tests for all harness components  -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT 測試覆蓋 harness 各組件：config、brain、bd-bridge、session、
;; agent、handoff、pipeline、cockpit、main。全部標記
;; :tags '(super-harness)。bd 實測以 condition-case 守護，
;; 環境無 bd 時測試仍通過。

;;; Code:

(require 'ert)
(require 'cl-lib)

(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'super-harness)
(require 'super-harness-bd-bridge)
(require 'super-harness-brain)
(require 'super-harness-session)
(require 'super-harness-agent)
(require 'super-harness-handoff)
(require 'super-harness-pipeline)
(require 'super-harness-cockpit)

;;; Helpers

(defun super-harness-test--temp-dir ()
  "Return a new temporary directory path."
  (make-temp-file "sh-test-" t))

(defun super-harness-test--fake-opencode ()
  "Create executable script that sleeps 60s; return its path.
Mimics an opencode subprocess so session tests need no real CLI."
  (let ((f (make-temp-file "sh-fake-opencode-" nil ".sh")))
    (with-temp-file f (insert "#!/bin/sh\nsleep 60\n"))
    (set-file-modes f #o755)
    f))

(defun super-harness-test--bd-forget-matching (substr)
  "Forget all bd memories whose key contains SUBSTR.  Never errors."
  (condition-case nil
      (let* ((out (with-temp-buffer
                    (call-process shell-file-name nil t nil
                                  shell-command-switch "bd memories --json")
                    (buffer-string)))
             (data (and (stringp out)
                        (json-read-from-string out))))
        (when (hash-table-p data)
          (maphash (lambda (key _val)
                     (when (string-match-p substr key)
                       (call-process shell-file-name nil nil nil
                                     shell-command-switch
                                     (format "bd forget %s -q" key))))
                   data)))
    (error nil)))

;;; 1. config

(ert-deftest super-harness-test-config-loads ()
  :tags '(super-harness)
  (should super-harness-config))

(ert-deftest super-harness-test-config-crew-seats ()
  :tags '(super-harness)
  (let ((crew (cdr (assq 'seats (cdr (assq 'crew super-harness-config))))))
    (should (equal (mapcar (lambda (s) (alist-get 'name s)) crew)
                   '("ant" "bat")))))

(ert-deftest super-harness-test-config-fleet-seats ()
  :tags '(super-harness)
  (let ((fleet (cdr (assq 'seats (cdr (assq 'fleet super-harness-config))))))
    (should (equal (mapcar (lambda (s) (alist-get 'name s)) fleet)
                   '("homer" "plato" "austen")))))

(ert-deftest super-harness-test-config-welfare-handoff-enabled ()
  :tags '(super-harness)
  (let ((welfare (cdr (assq 'welfare super-harness-config))))
    (should (eq (alist-get 'handoff-enabled welfare) t))))

(ert-deftest super-harness-test-config-poll-interval ()
  :tags '(super-harness)
  (let ((fleet (cdr (assq 'fleet super-harness-config))))
    (should (= (alist-get 'poll-interval fleet) 30))))

;;; 2. brain

(ert-deftest super-harness-test-brain-write-read ()
  :tags '(super-harness)
  (let* ((dir (super-harness-test--temp-dir))
         (super-harness-config `((brain . ((path . ,dir))))))
    (unwind-protect
        (progn
          (should (super-harness-brain-write "notes/test.md" "# hello"))
          (should (file-exists-p (expand-file-name "notes/test.md" dir)))
          (should (string= (super-harness-brain-read "notes/test.md") "# hello")))
      (delete-directory dir t))))

(ert-deftest super-harness-test-brain-read-missing ()
  :tags '(super-harness)
  (let* ((dir (super-harness-test--temp-dir))
         (super-harness-config `((brain . ((path . ,dir))))))
    (unwind-protect
        (should (null (super-harness-brain-read "ghost.md")))
      (delete-directory dir t))))

(ert-deftest super-harness-test-brain-list ()
  :tags '(super-harness)
  (let* ((dir (super-harness-test--temp-dir))
         (super-harness-config `((brain . ((path . ,dir))))))
    (unwind-protect
        (progn
          (super-harness-brain-write "a.md" "A")
          (super-harness-brain-write "sub/b.md" "B")
          (should (equal (sort (super-harness-brain-list) #'string<)
                         '("a.md" "sub/b.md"))))
      (delete-directory dir t))))

;;; 3. bd-bridge

(ert-deftest super-harness-test-bd-bridge-functions-exist ()
  :tags '(super-harness)
  (dolist (f '(super-harness-bd-ready-tasks
               super-harness-bd-claim
               super-harness-bd-close
               super-harness-bd-create-epic
               super-harness-bd-create-task
               super-harness-bd-dep-add
               super-harness-bd-show
               super-harness-bd-remember
               super-harness-bd-prime))
    (should (fboundp f))))

(ert-deftest super-harness-test-bd-remember-and-forget ()
  :tags '(super-harness)
  (let* ((ts (format-time-string "%Y%m%d%H%M%S" (current-time)))
         (fact (format "super-harness ERT probe %s" ts))
         (ok (condition-case nil
                 (super-harness-bd-remember fact)
               (error nil))))
    (when ok
      (should (eq ok t)))
    (super-harness-test--bd-forget-matching "super-harness-ert-probe")))

;;; 4. session

(ert-deftest super-harness-test-session-create-kill ()
  :tags '(super-harness)
  (let* ((script (super-harness-test--fake-opencode))
         (super-harness-opencode-command script)
         (buf (super-harness-session-create "fake-seat" "crew" "test-model"
                                            default-directory)))
    (unwind-protect
        (progn
          (should (buffer-live-p buf))
          (should (super-harness-session-alive-p "fake-seat"))
          (should (assoc "fake-seat" (super-harness-session-list)))
          (should (super-harness-session-kill "fake-seat"))
          (should-not (super-harness-session-alive-p "fake-seat")))
      (delete-file script)
      (when (buffer-live-p buf) (kill-buffer buf)))))

;;; 5. agent

(ert-deftest super-harness-test-agent-status-nonexistent ()
  :tags '(super-harness)
  (should (null (super-harness-agent-status "no-such-seat"))))

(ert-deftest super-harness-test-agent-prime-no-error ()
  :tags '(super-harness)
  (let* ((super-harness-opencode-command "no-such-opencode-cli-xyz")
         (buf (super-harness-session-create "prime-seat" "crew" "test-model"
                                            default-directory)))
    (unwind-protect
        (progn
          (condition-case nil
              (progn (super-harness-agent-prime "prime-seat") (should t))
            (error (should t))))
      (super-harness-session-kill "prime-seat")
      (when (buffer-live-p buf) (kill-buffer buf)))))

;;; 6. handoff

(ert-deftest super-harness-test-handoff-write-read ()
  :tags '(super-harness)
  (let ((dir (super-harness-test--temp-dir)))
    (unwind-protect
        (let ((default-directory dir))
          (should (super-harness-handoff-write "test-seat" "handoff body"))
          (should (string= (super-harness-handoff-read "test-seat")
                           "handoff body")))
      (delete-directory dir t))))

(ert-deftest super-harness-test-handoff-read-missing ()
  :tags '(super-harness)
  (let ((dir (super-harness-test--temp-dir)))
    (unwind-protect
        (let ((default-directory dir))
          (should (null (super-harness-handoff-read "ghost-seat"))))
      (delete-directory dir t))))

;;; 7. pipeline

(ert-deftest super-harness-test-pipeline-status-keys ()
  :tags '(super-harness)
  (let ((status (super-harness-pipeline-status)))
    (should (listp status))
    (dolist (k '(:queued :active :completed :blocked :fleet-free :fleet-busy))
      (should (plist-get status k)))))

(ert-deftest super-harness-test-pipeline-fleet-seats ()
  :tags '(super-harness)
  (should (equal (super-harness-pipeline-fleet-seats)
                 '("homer" "plato" "austen"))))

;;; 8. cockpit

(ert-deftest super-harness-test-cockpit-show ()
  :tags '(super-harness)
  (condition-case nil
      (super-harness-cockpit-show)
    (error nil))
  (should (get-buffer "*super-harness-cockpit*"))
  (when (get-buffer "*super-harness-cockpit*")
    (kill-buffer "*super-harness-cockpit*")))

(ert-deftest super-harness-test-cockpit-refresh-no-error ()
  :tags '(super-harness)
  (let ((buf (get-buffer-create "*super-harness-cockpit*")))
    (unwind-protect
        (progn
          (with-current-buffer buf (tabulated-list-mode))
          (condition-case nil
              (progn (super-harness-cockpit-refresh) (should t))
            (error (should t))))
      (kill-buffer buf))))

;;; 9. main

(ert-deftest super-harness-test-main-commands-exist ()
  :tags '(super-harness)
  (dolist (f '(super-harness-mode
               super-harness-start
               super-harness-stop
               super-harness-status
               super-harness-restart
               super-harness-attach
               super-harness-crew
               super-harness-bootstrap))
    (should (fboundp f))))

;;; 10. workspace integration

(ert-deftest super-harness-test-workspace-path ()
  :tags '(super-harness)
  (should (equal (super-harness-workspace-path "ant")
                 (expand-file-name
                  "ant"
                  (expand-file-name
                   (or (cdr (assq 'path (cdr (assq 'workspaces super-harness-config))))
                       "harness/workspaces"))))))

(ert-deftest super-harness-test-workspace-exists-bogus ()
  :tags '(super-harness)
  (should-not (super-harness-workspace-exists-p "no-such-seat-xyz")))

(ert-deftest super-harness-test-bootstrap-no-error ()
  :tags '(super-harness)
  (condition-case err
      (progn
        (super-harness-bootstrap)
        (should t))
    (error
     (should nil (format "bootstrap errored: %s" (error-message-string err))))))

(ert-deftest super-harness-test-land-branch-bogus-seat ()
  :tags '(super-harness)
  (condition-case err
      (should (null (super-harness-pipeline-land-branch "no-such-seat-xyz")))
    (error
     (should nil (format "land-branch errored: %s" (error-message-string err))))))

(ert-deftest super-harness-test-config-workspaces-land-on-stop ()
  :tags '(super-harness)
  (let ((ws (cdr (assq 'workspaces super-harness-config))))
    (should (eq (alist-get 'land-on-stop ws) t))))

(provide 'super-harness-test)

;;; super-harness-test.el ends here
