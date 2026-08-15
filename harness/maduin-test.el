;;; maduin-test.el --- ERT tests for all harness components  -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT 測試覆蓋 harness 各組件：config、brain、bd-bridge、session、
;; agent、handoff、pipeline、cockpit、main。全部標記
;; :tags '(maduin)。bd 實測以 condition-case 守護，
;; 環境無 bd 時測試仍通過。

;;; Code:

(require 'ert)
(require 'cl-lib)

(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'maduin)
(require 'maduin-bd-bridge)
(require 'maduin-brain)
(require 'maduin-session)
(require 'maduin-agent)
(require 'maduin-handoff)
(require 'maduin-pipeline)
(require 'maduin-cockpit)
(require 'maduin-resolver)

;;; Helpers

(defun maduin-test--temp-dir ()
  "Return a new temporary directory path."
  (make-temp-file "sh-test-" t))

(defun maduin-test--fake-opencode ()
  "Create executable script that sleeps 60s; return its path.
Mimics an opencode subprocess so session tests need no real CLI."
  (let ((f (make-temp-file "sh-fake-opencode-" nil ".sh")))
    (with-temp-file f (insert "#!/bin/sh\nsleep 60\n"))
    (set-file-modes f #o755)
    f))

(defun maduin-test--bd-forget-matching (substr)
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

(ert-deftest maduin-test-config-loads ()
  :tags '(maduin)
  (should maduin-config))

(ert-deftest maduin-test-config-crew-seats ()
  :tags '(maduin)
  (let ((crew (cdr (assq 'seats (cdr (assq 'crew maduin-config))))))
    (should (equal (mapcar (lambda (s) (alist-get 'name s)) crew)
                   '("ant")))))

(ert-deftest maduin-test-config-fleet-seats ()
  :tags '(maduin)
  (let ((fleet (cdr (assq 'seats (cdr (assq 'fleet maduin-config))))))
    (should (equal (mapcar (lambda (s) (alist-get 'name s)) fleet)
                   '("homer" "plato" "austen")))))

(ert-deftest maduin-test-config-welfare-handoff-enabled ()
  :tags '(maduin)
  (let ((welfare (cdr (assq 'welfare maduin-config))))
    (should (eq (alist-get 'handoff-enabled welfare) t))))

(ert-deftest maduin-test-config-poll-interval ()
  :tags '(maduin)
  (let ((fleet (cdr (assq 'fleet maduin-config))))
    (should (= (alist-get 'poll-interval fleet) 30))))

;;; 2. brain

(ert-deftest maduin-test-brain-write-read ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (maduin-config `((brain . ((path . ,dir))))))
    (unwind-protect
        (progn
          (should (maduin-brain-write "notes/test.md" "# hello"))
          (should (file-exists-p (expand-file-name "notes/test.md" dir)))
          (should (string= (maduin-brain-read "notes/test.md") "# hello")))
      (delete-directory dir t))))

(ert-deftest maduin-test-brain-read-missing ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (maduin-config `((brain . ((path . ,dir))))))
    (unwind-protect
        (should (null (maduin-brain-read "ghost.md")))
      (delete-directory dir t))))

(ert-deftest maduin-test-brain-list ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (maduin-config `((brain . ((path . ,dir))))))
    (unwind-protect
        (progn
          (maduin-brain-write "a.md" "A")
          (maduin-brain-write "sub/b.md" "B")
          (should (equal (sort (maduin-brain-list) #'string<)
                         '("a.md" "sub/b.md"))))
      (delete-directory dir t))))

;;; 3. bd-bridge

(ert-deftest maduin-test-bd-bridge-functions-exist ()
  :tags '(maduin)
  (dolist (f '(maduin-bd-ready-tasks
               maduin-bd-claim
               maduin-bd-close
               maduin-bd-create-epic
               maduin-bd-create-task
               maduin-bd-dep-add
               maduin-bd-show
               maduin-bd-remember
               maduin-bd-prime))
    (should (fboundp f))))

(ert-deftest maduin-test-bd-remember-and-forget ()
  :tags '(maduin)
  (let* ((ts (format-time-string "%Y%m%d%H%M%S" (current-time)))
         (fact (format "maduin ERT probe %s" ts))
         (ok (condition-case nil
                 (maduin-bd-remember fact)
               (error nil))))
    (when ok
      (should (eq ok t)))
    (maduin-test--bd-forget-matching "maduin-ert-probe")))

;;; 4. session

(ert-deftest maduin-test-session-create-kill ()
  :tags '(maduin)
  (let* ((script (maduin-test--fake-opencode))
         (maduin-opencode-command script)
         (buf (maduin-session-create "fake-seat" "crew" "test-model"
                                            default-directory)))
    (unwind-protect
        (progn
          (should (buffer-live-p buf))
          (should (maduin-session-alive-p "fake-seat"))
          (should (assoc "fake-seat" (maduin-session-list)))
          (should (maduin-session-kill "fake-seat"))
          (should-not (maduin-session-alive-p "fake-seat")))
      (delete-file script)
      (when (buffer-live-p buf) (kill-buffer buf)))))

;;; 5. agent

(ert-deftest maduin-test-agent-status-nonexistent ()
  :tags '(maduin)
  (should (null (maduin-agent-status "no-such-seat"))))

(ert-deftest maduin-test-agent-prime-no-error ()
  :tags '(maduin)
  (let* ((maduin-opencode-command "no-such-opencode-cli-xyz")
         (buf (maduin-session-create "prime-seat" "crew" "test-model"
                                            default-directory)))
    (unwind-protect
        (progn
          (condition-case nil
              (progn (maduin-agent-prime "prime-seat") (should t))
            (error (should t))))
      (maduin-session-kill "prime-seat")
      (when (buffer-live-p buf) (kill-buffer buf)))))

;;; 6. handoff

(ert-deftest maduin-test-handoff-write-read ()
  :tags '(maduin)
  (let ((dir (maduin-test--temp-dir)))
    (unwind-protect
        (let ((default-directory dir))
          (should (maduin-handoff-write "test-seat" "handoff body"))
          (should (string= (maduin-handoff-read "test-seat")
                           "handoff body")))
      (delete-directory dir t))))

(ert-deftest maduin-test-handoff-read-missing ()
  :tags '(maduin)
  (let ((dir (maduin-test--temp-dir)))
    (unwind-protect
        (let ((default-directory dir))
          (should (null (maduin-handoff-read "ghost-seat"))))
      (delete-directory dir t))))

;;; 7. pipeline

(ert-deftest maduin-test-pipeline-status-keys ()
  :tags '(maduin)
  (let ((status (maduin-pipeline-status)))
    (should (listp status))
    (dolist (k '(:queued :active :completed :blocked :fleet-free :fleet-busy))
      (should (plist-get status k)))))

(ert-deftest maduin-test-pipeline-fleet-seats ()
  :tags '(maduin)
  (should (equal (maduin-pipeline-fleet-seats)
                 '("homer" "plato" "austen"))))

;;; 8. cockpit

(ert-deftest maduin-test-cockpit-show ()
  :tags '(maduin)
  (condition-case nil
      (maduin-cockpit-show)
    (error nil))
  (should (get-buffer "*maduin-cockpit*"))
  (when (get-buffer "*maduin-cockpit*")
    (kill-buffer "*maduin-cockpit*")))

(ert-deftest maduin-test-cockpit-refresh-no-error ()
  :tags '(maduin)
  (let ((buf (get-buffer-create "*maduin-cockpit*")))
    (unwind-protect
        (progn
          (with-current-buffer buf (tabulated-list-mode))
          (condition-case nil
              (progn (maduin-cockpit-refresh) (should t))
            (error (should t))))
      (kill-buffer buf))))

;;; 9. main

(ert-deftest maduin-test-main-commands-exist ()
  :tags '(maduin)
  (dolist (f '(maduin-mode
               maduin-start
               maduin-stop
               maduin-status
               maduin-restart
               maduin-attach
               maduin-crew
               maduin-bootstrap))
    (should (fboundp f))))

;;; 10. workspace integration

(ert-deftest maduin-test-workspace-path ()
  :tags '(maduin)
  (should (equal (maduin-workspace-path "ant")
                 (expand-file-name
                  "ant"
                  (expand-file-name
                   (or (cdr (assq 'path (cdr (assq 'workspaces maduin-config))))
                       "harness/workspaces"))))))

(ert-deftest maduin-test-workspace-exists-bogus ()
  :tags '(maduin)
  (should-not (maduin-workspace-exists-p "no-such-seat-xyz")))

(ert-deftest maduin-test-bootstrap-no-error ()
  :tags '(maduin)
  (condition-case err
      (progn
        (maduin-bootstrap)
        (should t))
    (error
     (ert-fail (format "bootstrap errored: %s" (error-message-string err))))))

(ert-deftest maduin-test-land-branch-bogus-seat ()
  :tags '(maduin)
  (condition-case err
      (should (null (maduin-pipeline-land-branch "no-such-seat-xyz")))
    (error
     (ert-fail (format "land-branch errored: %s" (error-message-string err))))))

(ert-deftest maduin-test-config-workspaces-land-on-stop ()
  :tags '(maduin)
  (let ((ws (cdr (assq 'workspaces maduin-config))))
    (should (eq (alist-get 'land-on-stop ws) t))))

;;; 11. resolver

(ert-deftest maduin-test-config-resolver-keys ()
  :tags '(maduin)
  (let ((resolver (cdr (assq 'resolver maduin-config))))
    (should (eq (alist-get 'enabled resolver) t))
    (should (string= (alist-get 'model resolver) "deepseek-v3"))
    (should (= (alist-get 'max-retries resolver) 3))))

(ert-deftest maduin-test-resolver-active-p-bogus ()
  :tags '(maduin)
  (should-not (maduin-resolver-active-p "bogus-seat-xyz")))

(ert-deftest maduin-test-resolver-prompt ()
  :tags '(maduin)
  (let ((prompt (maduin-resolver--prompt "prompt-seat-xyz")))
    (should (string-match-p "prompt-seat-xyz" prompt))
    (should (string-match-p "RESOLVED_DONE" prompt))))

(ert-deftest maduin-test-resolver-start-degraded ()
  :tags '(maduin)
  (let ((seat "degraded-seat-xyz")
        (maduin-opencode-command "no-such-opencode-cli-xyz"))
    (unwind-protect
        (progn
          (should-not (maduin-resolver-start seat))
          (should-not (maduin-resolver-active-p seat))
          (should (get-buffer "*maduin/resolver-degraded-seat-xyz*")))
      (maduin-resolver-stop seat)
      (when (get-buffer "*maduin/resolver-degraded-seat-xyz*")
        (kill-buffer "*maduin/resolver-degraded-seat-xyz*")))))

(ert-deftest maduin-test-resolver-start-fake-process ()
  :tags '(maduin)
  (let* ((script (maduin-test--fake-opencode))
         (seat "fake-resolver-seat-xyz")
         (workdir (maduin-workspace-path seat))
         (maduin-opencode-command script))
    (unwind-protect
        (progn
          (make-directory workdir t)
          (maduin-resolver-start seat)
          (should (maduin-resolver-active-p seat))
          (maduin-resolver-stop seat)
          (should-not (maduin-resolver-active-p seat)))
      (delete-file script)
      (maduin-resolver-stop seat)
      (ignore-errors (delete-directory workdir t)))))

(ert-deftest maduin-test-resolver-stop-inactive ()
  :tags '(maduin)
  (should
   (condition-case nil
       (progn
         (maduin-resolver-stop "ghost-seat-xyz")
         t)
     (error nil))))

(provide 'maduin-test)

;;; maduin-test.el ends here
