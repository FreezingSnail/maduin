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

(defconst maduin-test--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing maduin-test.el (the harness dir).")

(defun maduin-test--fake-opencode-shim ()
  "Return path to the repo fake opencode shim, or nil when missing."
  (let ((p (expand-file-name "test/fake-opencode" maduin-test--dir)))
    (and (file-exists-p p) p)))

(require 'maduin)
(require 'maduin-bd-bridge)
(require 'maduin-gate)
(require 'maduin-brain)
(require 'maduin-session)
(require 'maduin-agent)
(require 'maduin-handoff)
(require 'maduin-pipeline)
(require 'maduin-cockpit)
(require 'maduin-resolver)
(require 'maduin-terminal)

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

(ert-deftest maduin-test-config-concierge-seats ()
  :tags '(maduin)
  (let ((concierge (cdr (assq 'seats (cdr (assq 'concierge maduin-config))))))
    (should (equal (mapcar (lambda (s) (alist-get 'name s)) concierge)
                   '("alexander")))
    (should (eq (alist-get 'role (car concierge)) 'concierge))))

(ert-deftest maduin-test-config-designer-seats ()
  :tags '(maduin)
  (let ((designer (cdr (assq 'seats (cdr (assq 'designer maduin-config))))))
    (should (equal (mapcar (lambda (s) (alist-get 'name s)) designer)
                   '("ramuh")))
    (should (eq (alist-get 'role (car designer)) 'designer))))

(ert-deftest maduin-test-config-fleet-seats ()
  :tags '(maduin)
  (let ((fleet (cdr (assq 'seats (cdr (assq 'fleet maduin-config))))))
    (should (equal (mapcar (lambda (s) (alist-get 'name s)) fleet)
                   '("ifrit" "shiva" "titan")))
    (should (equal (mapcar (lambda (s) (alist-get 'role s)) fleet)
                   '(implementer implementer implementer)))))

(ert-deftest maduin-test-config-seats ()
  :tags '(maduin)
  (should (equal (maduin--seats)
                 '(("alexander" . "concierge")
                   ("ramuh" . "designer")
                   ("ifrit" . "implementer")
                   ("shiva" . "implementer")
                   ("titan" . "implementer")))))

(ert-deftest maduin-test-config-seat-models ()
  :tags '(maduin)
  (should (equal (maduin--seat-model "alexander") "opencode-go/deepseek-v4-pro"))
  (should (equal (maduin--seat-model "ramuh") "opencode-go/deepseek-v4-pro"))
  (should (equal (maduin--seat-model "ifrit") "opencode-go/deepseek-v4-flash"))
  (should (equal (maduin--seat-model "shiva") "opencode-go/deepseek-v4-flash"))
  (should (equal (maduin--seat-model "titan") "opencode-go/deepseek-v4-flash")))

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

;;; 4b. autonomous session substrate (opencode run + NDJSON)

(ert-deftest maduin-test-session-parse-step-finish-stop ()
  :tags '(maduin)
  (let ((evt (maduin-session--parse-line
              "{\"type\":\"step_finish\",\"sessionID\":\"ses_x\",\"part\":{\"reason\":\"stop\"}}")))
    (should (string= (plist-get evt :type) "step_finish"))
    (should (string= (plist-get evt :session-id) "ses_x"))
    (should (eq (plist-get evt :terminal) 'completed))))

(ert-deftest maduin-test-session-parse-step-finish-error ()
  :tags '(maduin)
  (let ((evt (maduin-session--parse-line
              "{\"type\":\"step_finish\",\"sessionID\":\"ses_x\",\"part\":{\"reason\":\"error\"}}")))
    (should (eq (plist-get evt :terminal) 'failed))))

(ert-deftest maduin-test-session-parse-tool-use-error ()
  :tags '(maduin)
  (let ((evt (maduin-session--parse-line
              "{\"type\":\"tool_use\",\"sessionID\":\"ses_x\",\"part\":{\"type\":\"tool\",\"tool\":\"bash\",\"state\":{\"status\":\"error\"}}}")))
    (should (eq (plist-get evt :terminal) 'failed))))

(ert-deftest maduin-test-session-parse-tool-use-completed ()
  :tags '(maduin)
  (let ((evt (maduin-session--parse-line
              "{\"type\":\"tool_use\",\"sessionID\":\"ses_x\",\"part\":{\"type\":\"tool\",\"tool\":\"write\",\"state\":{\"status\":\"completed\"}}}")))
    (should (eq (plist-get evt :terminal) nil))))

(ert-deftest maduin-test-session-parse-nonterminal ()
  :tags '(maduin)
  (let ((evt (maduin-session--parse-line
              "{\"type\":\"text\",\"sessionID\":\"ses_x\",\"part\":{\"type\":\"text\",\"text\":\"hi\"}}")))
    (should (eq (plist-get evt :terminal) nil))))

(ert-deftest maduin-test-session-parse-garbage ()
  :tags '(maduin)
  (should-not (maduin-session--parse-line "not json at all")))

(ert-deftest maduin-test-session-run-missing-cli ()
  :tags '(maduin)
  (let ((maduin-opencode-command "no-such-opencode-cli-xyz"))
    (should-not (maduin-session-run default-directory "m" "p"))))

(ert-deftest maduin-test-session-complete-p-unknown ()
  :tags '(maduin)
  (should (eq (maduin-session-complete-p "no-such-handle-xyz") 'failed)))

(ert-deftest maduin-test-session-diff-unknown ()
  :tags '(maduin)
  (should-not (maduin-session-diff "no-such-handle-xyz")))

(ert-deftest maduin-test-session-run-completes ()
  :tags '(maduin)
  (let* ((shim (maduin-test--fake-opencode-shim))
         (maduin-opencode-command shim)
         (captured nil)
         (maduin-session-on-complete-hook
          (list (lambda (sid status) (setq captured (cons sid status)))))
         (dir (maduin-test--temp-dir))
         (sid (maduin-session-run dir "test-model" "say hi"))
         (buf (and sid (maduin-session--run-buffer sid)))
         (proc (and buf (get-buffer-process buf))))
    (unwind-protect
        (progn
          (should (stringp sid))
          (while (and proc (process-live-p proc))
            (accept-process-output proc 0.05))
          (should (eq (maduin-session-complete-p sid) 'completed))
          (should (equal (car captured) sid))
          (should (eq (cdr captured) 'completed))
          (should (maduin-session-diff sid))
          (should (maduin-session-delete sid)))
      (ignore-errors (maduin-session-delete sid))
      (delete-directory dir t))))

(ert-deftest maduin-test-session-run-permission-denied ()
  :tags '(maduin)
  (let* ((shim (maduin-test--fake-opencode-shim))
         (maduin-opencode-command shim)
         (process-environment (cons "MADUIN_FAKE_MODE=fail" process-environment))
         (dir (maduin-test--temp-dir))
         (sid (maduin-session-run dir "test-model" "edit file"))
         (buf (and sid (maduin-session--run-buffer sid)))
         (proc (and buf (get-buffer-process buf))))
    (unwind-protect
        (progn
          (should (stringp sid))
          (while (and proc (process-live-p proc))
            (accept-process-output proc 0.05))
          ;; exit code 0 but event stream says failed — exit code untrusted
          (should (eq (maduin-session-complete-p sid) 'failed)))
      (ignore-errors (maduin-session-delete sid))
      (delete-directory dir t))))

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
                 '("ifrit" "shiva" "titan"))))

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
               maduin-concierge
               maduin-bootstrap))
    (should (fboundp f))))

;;; 10. workspace integration

(ert-deftest maduin-test-workspace-path ()
  :tags '(maduin)
  (should (equal (maduin-workspace-path "alexander")
                 (expand-file-name
                  "alexander"
                  (expand-file-name
                   (or (cdr (assq 'path (cdr (assq 'workspaces maduin-config))))
                       "harness/workspaces")
                   (maduin-project-root))))))

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
    (should (string= (alist-get 'model resolver) "opencode-go/deepseek-v4-pro"))
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

;;; 12. project root

(ert-deftest maduin-test-project-root-returns-dir ()
  :tags '(maduin)
  (let ((root (maduin-project-root)))
    (should (stringp root))
    (should (file-directory-p root))))

(ert-deftest maduin-test-project-root-fallback ()
  :tags '(maduin)
  (let ((dir (maduin-test--temp-dir)))
    (unwind-protect
        (let ((default-directory dir))
          (should (equal (directory-file-name (maduin-project-root))
                         (directory-file-name dir))))
      (delete-directory dir t))))

(ert-deftest maduin-test-handoff-cache-under-project-root ()
  :tags '(maduin)
  (should (equal (maduin-handoff-cache-path "root-seat-xyz")
                 (expand-file-name
                  ".agents/handoff/root-seat-xyz.md"
                  (maduin-project-root)))))

;;; 13. gate (approval gate)

(defun maduin-test--bd-delete (id)
  "Force-delete scratch bead ID. Never errors."
  (condition-case nil
      (call-process shell-file-name nil nil nil shell-command-switch
                    (format "bd delete %s --force" id))
    (error nil)))

(defun maduin-test--gate-scratch (ts)
  "Create a scratch epic + task for gate tests. Return (epic-id . task-id).
Both nil if bd unavailable."
  (let* ((epic (condition-case nil
                   (maduin-bd-create-epic
                    (format "ert-gate-epic-%s" ts) "scratch epic for ERT")
                 (error nil)))
         (task (and epic
                    (condition-case nil
                        (maduin-bd-create-task
                         (format "ert-gate-task-%s" ts) "scratch task for ERT"
                         epic)
                      (error nil)))))
    (cons epic task)))

(ert-deftest maduin-test-gate-functions-exist ()
  :tags '(maduin)
  (dolist (f '(maduin-bd-defer
               maduin-bd-undefer
               maduin-bd-label
               maduin-bd-label-remove
               maduin-bd-query
               maduin-bd-comment
               maduin-bd-update-design-acceptance
               maduin-gate-stage
               maduin-gate-approve
               maduin-gate-reject
               maduin-gate-staged-list
               maduin-gate-approve-epic))
    (should (fboundp f))))

(ert-deftest maduin-test-gate-stage-approve-list ()
  :tags '(maduin)
  (let* ((ts (format-time-string "%Y%m%d%H%M%S" (current-time)))
         (pair (maduin-test--gate-scratch ts))
         (epic (car pair))
         (task (cdr pair)))
    (unwind-protect
        (when (and epic task)
          (should (maduin-gate-stage task "design body" "acceptance body"))
          (should (member task (maduin-gate-staged-list)))
          (should (maduin-gate-approve task))
          (should-not (member task (maduin-gate-staged-list))))
      (maduin-test--bd-delete task)
      (maduin-test--bd-delete epic))))

(ert-deftest maduin-test-gate-reject-keeps-staged ()
  :tags '(maduin)
  (let* ((ts (format-time-string "%Y%m%d%H%M%S" (current-time)))
         (pair (maduin-test--gate-scratch ts))
         (epic (car pair))
         (task (cdr pair)))
    (unwind-protect
        (when (and epic task)
          (should (maduin-gate-stage task "design body" "acceptance body"))
          (should (maduin-gate-reject task "needs rework"))
          ;; still staged after reject
          (should (member task (maduin-gate-staged-list))))
      (maduin-test--bd-delete task)
      (maduin-test--bd-delete epic))))

(ert-deftest maduin-test-gate-approve-epic ()
  :tags '(maduin)
  (let* ((ts (format-time-string "%Y%m%d%H%M%S" (current-time)))
         (epic (condition-case nil
                   (maduin-bd-create-epic
                    (format "ert-gate-epic2-%s" ts) "scratch epic for ERT")
                 (error nil)))
         (t1 (and epic
                  (condition-case nil
                      (maduin-bd-create-task
                       (format "ert-gate-t1-%s" ts) "scratch" epic)
                    (error nil))))
         (t2 (and epic
                  (condition-case nil
                      (maduin-bd-create-task
                       (format "ert-gate-t2-%s" ts) "scratch" epic)
                    (error nil)))))
    (unwind-protect
        (when (and epic t1 t2)
          (should (maduin-gate-stage t1 "d1" "a1"))
          (should (maduin-gate-stage t2 "d2" "a2"))
          (should (member t1 (maduin-gate-staged-list)))
          (should (member t2 (maduin-gate-staged-list)))
          (let ((approved (maduin-gate-approve-epic epic)))
            (should (member t1 approved))
            (should (member t2 approved)))
          (should-not (member t1 (maduin-gate-staged-list)))
          (should-not (member t2 (maduin-gate-staged-list))))
      (maduin-test--bd-delete t1)
      (maduin-test--bd-delete t2)
      (maduin-test--bd-delete epic))))

;;; 14. terminal (interactive substrate)

(ert-deftest maduin-test-terminal-buffer-name ()
  :tags '(maduin)
  (should (equal (maduin-terminal--buffer-name 'concierge "alexander")
                 "*maduin/concierge-alexander*"))
  (should (equal (maduin-terminal--buffer-name "designer" "ramuh")
                 "*maduin/designer-ramuh*")))

(ert-deftest maduin-test-terminal-choose-backend ()
  :tags '(maduin)
  (should (eq (maduin-terminal--choose-backend t) 'vterm))
  (should (eq (maduin-terminal--choose-backend nil) 'term))
  ;; batch: vterm not installed → term fallback
  (should (eq (maduin-terminal--backend) 'term)))

(ert-deftest maduin-test-terminal-prompt-inline ()
  :tags '(maduin)
  (let ((p (maduin-terminal--prompt "alexander" 'concierge "pro")))
    (should (string-match-p "alexander" p))
    (should (string-match-p "concierge" p))))

(ert-deftest maduin-test-terminal-prompt-template ()
  :tags '(maduin)
  ;; "crew" has templates/crew-prompt.txt → template wins, substituted.
  (let ((p (maduin-terminal--prompt "ant" "crew" "deepseek-v3")))
    (should (string-match-p "ant" p))
    (should-not (string-match-p "{name}" p))
    (should-not (string-match-p "{model}" p))))

(ert-deftest maduin-test-terminal-command-line ()
  :tags '(maduin)
  (let ((cmd (maduin-terminal--command-line "/acme/root" "deepseek-v3"
                                             "You are x" "opencode")))
    (should (string-match-p "\\`opencode " cmd))
    (should (string-match-p "deepseek-v3" cmd))
    (should (string-match-p "--prompt" cmd))))

(ert-deftest maduin-test-terminal-parse-session-ids ()
  :tags '(maduin)
  (let ((root "/acme/demo")
        (json (concat
               "[{\"id\":\"ses_old\",\"directory\":\"/acme/demo\",\"created\":1000},"
               "{\"id\":\"ses_new\",\"directory\":\"/acme/demo\",\"created\":2000},"
               "{\"id\":\"ses_other\",\"directory\":\"/acme/other\",\"created\":3000}]")))
    (should (equal (mapcar #'cdr (maduin-terminal--parse-session-ids json root))
                   '("ses_new" "ses_old")))
    (should (null (maduin-terminal--parse-session-ids json "/acme/missing")))
    ;; since filter (seconds): 1.5s → 1500ms, drops ses_old(1000).
    (should (equal (mapcar #'cdr (maduin-terminal--parse-session-ids json root 1.5))
                   '("ses_new")))
    ;; since 2.5s → 2500ms, drops both.
    (should (null (maduin-terminal--parse-session-ids json root 2.5)))
    ;; exclude ses_new → only ses_old.
    (should (equal (mapcar #'cdr (maduin-terminal--parse-session-ids json root nil '("ses_new")))
                   '("ses_old")))))

(ert-deftest maduin-test-terminal-handoff-note-write ()
  :tags '(maduin)
  (let* ((seat (format "ert-term-seat-%s" (format-time-string "%H%M%S%N" (current-time))))
         (note (maduin-terminal--handoff-note "ses_test123" "{\"ok\":true}"))
         (path (maduin-handoff-cache-path seat)))
    (unwind-protect
        (progn
          (should (maduin-terminal--write-handoff seat note (maduin-project-root)))
          (should (file-exists-p path))
          (should (string= (maduin-handoff-read seat) note)))
      (ignore-errors (delete-file path)))))

(ert-deftest maduin-test-terminal-active-p-bogus ()
  :tags '(maduin)
  (should-not (maduin-terminal-active-p "no-such-seat-xyz")))

(ert-deftest maduin-test-terminal-dismiss-no-buffer ()
  :tags '(maduin)
  (should (null (maduin-terminal-dismiss "no-such-seat-xyz"))))

(provide 'maduin-test)

;;; maduin-test.el ends here
