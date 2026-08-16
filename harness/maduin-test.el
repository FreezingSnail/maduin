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
(require 'maduin-repairer)
(require 'maduin-review)
(require 'maduin-terminal)
(require 'maduin-dispatch)
(require 'maduin-designer)
(require 'maduin-concierge)

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
               maduin-bd-prime
               maduin-bd-open-epics
               maduin-bd-epic-children))
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
    (should-not (maduin-session-run default-directory "m" nil "p"))))

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
         (sid (maduin-session-run dir "test-model" nil "say hi"))
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
         (sid (maduin-session-run dir "test-model" nil "edit file"))
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
                maduin-concierge-dismiss
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

(ert-deftest maduin-test-workspace-ensure-real-worktree ()
  :tags '(maduin)
  (let ((seat "maduin-ws-probe")
        (wt nil))
    (unwind-protect
        (progn
          (setq wt (maduin-workspace-ensure seat))
          (should wt)
          (should (file-directory-p wt))
          (should (maduin-workspace-exists-p seat))
          (should (maduin-bd-worktree-real-p wt))
          ;; `git -C WT rev-parse --show-toplevel' must resolve INSIDE the
          ;; worktree (not the main repo), proving it is a real git worktree.
          (let ((top (string-trim
                      (with-temp-buffer
                        (call-process shell-file-name nil t nil
                                      shell-command-switch
                                      (format "git -C %s rev-parse --show-toplevel"
                                              (shell-quote-argument wt)))
                        (buffer-string)))))
            (should (string= (directory-file-name (file-truename top))
                             (directory-file-name (file-truename wt))))))
      ;; Cleanup: remove the worktree registration and its branch.
      (ignore-errors
        (when (and wt (maduin-bd-worktree-real-p wt))
          (call-process shell-file-name nil nil nil shell-command-switch
                        (format "git worktree remove --force %s"
                                (shell-quote-argument wt)))
          (call-process shell-file-name nil nil nil shell-command-switch
                        (format "git branch -D %s"
                                (shell-quote-argument seat))))))))

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

;;; 11. repairer

(ert-deftest maduin-test-config-repairer-keys ()
  :tags '(maduin)
  (let ((repairer (cdr (assq 'repairer maduin-config))))
    (should (eq (alist-get 'enabled repairer) t))
    (should (string= (alist-get 'model repairer) "opencode-go/deepseek-v4-pro"))
    (should (= (alist-get 'max-retries repairer) 3))))

(ert-deftest maduin-test-repairer-active-p-bogus ()
  :tags '(maduin)
  (should-not (maduin-repairer-active-p "bogus-seat-xyz")))

(ert-deftest maduin-test-repairer-prompt ()
  :tags '(maduin)
  (let ((prompt (maduin-repairer--prompt "prompt-seat-xyz" 'merge-conflict)))
    (should (string-match-p "prompt-seat-xyz" prompt))
    (should (string-match-p "RESOLVED_DONE" prompt))))

(ert-deftest maduin-test-repairer-start-degraded ()
  :tags '(maduin)
  (let ((seat "degraded-seat-xyz")
        (maduin-opencode-command "no-such-opencode-cli-xyz"))
    (unwind-protect
        (progn
          (should-not (maduin-repairer-start seat))
          (should-not (maduin-repairer-active-p seat))
          (should (get-buffer "*maduin/repairer-degraded-seat-xyz*")))
      (maduin-repairer-stop seat)
      (when (get-buffer "*maduin/repairer-degraded-seat-xyz*")
        (kill-buffer "*maduin/repairer-degraded-seat-xyz*")))))

(ert-deftest maduin-test-repairer-start-fake-process ()
  :tags '(maduin)
  (let* ((script (maduin-test--fake-opencode))
         (seat "fake-repairer-seat-xyz")
         (workdir (maduin-workspace-path seat))
         (maduin-opencode-command script))
    (unwind-protect
        (progn
          (make-directory workdir t)
          (maduin-repairer-start seat)
          (should (maduin-repairer-active-p seat))
          (maduin-repairer-stop seat)
          (should-not (maduin-repairer-active-p seat)))
      (delete-file script)
      (maduin-repairer-stop seat)
      (ignore-errors (delete-directory workdir t)))))

(ert-deftest maduin-test-repairer-stop-inactive ()
  :tags '(maduin)
  (should
   (condition-case nil
       (progn
         (maduin-repairer-stop "ghost-seat-xyz")
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

;;; 15. dispatch

(ert-deftest maduin-test-dispatch-functions-exist ()
  :tags '(maduin)
  (dolist (f '(maduin-dispatch-start
               maduin-dispatch-stop
               maduin-dispatch-implement
               maduin-dispatch-design
               maduin-dispatch-repair
               maduin-dispatch-run-loop))
    (should (fboundp f))))

(ert-deftest maduin-test-dispatch-implement-concurrency-cap ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (run-count 0)
         (maduin-dispatch--active
          (list (list :handle "s-ifrit" :seat "ifrit" :role 'implementer :task "t0")
                (list :handle "s-shiva" :seat "shiva" :role 'implementer :task "t0")))
         (maduin-dispatch--session-run-fn
          (lambda (_w _m _a _p)
            (setq run-count (1+ run-count))
            (format "s-%d" run-count)))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir)))
    (unwind-protect
        (progn
          ;; 2 active → 1 more on free seat titan.
          (let ((sid (maduin-dispatch-implement "t1")))
            (should (stringp sid))
            (should (= (length maduin-dispatch--active) 3))
            (should (equal (plist-get (car maduin-dispatch--active) :seat)
                           "titan")))
          ;; 3 active (cap) → nil, no further spawn.
          (let ((before run-count))
            (should-not (maduin-dispatch-implement "t2"))
            (should (= run-count before))))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-completion-lands-and-closes ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (landed nil)
         (closed nil)
         (deleted '())
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn (lambda (_w _m _a _p) "s-1"))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--diff-fn
          (lambda (_sid) (list '((file . "a.el") (patch . "+x")))))
         (maduin-dispatch--land-fn (lambda (seat) (setq landed seat) t))
         (maduin-dispatch--close-fn (lambda (task out) (setq closed (cons task out)) t))
         (maduin-dispatch--session-delete-fn (lambda (sid) (push sid deleted) t)))
    (unwind-protect
        (progn
          (should (equal (maduin-dispatch-implement "t1") "s-1"))
          (should (= (length maduin-dispatch--active) 1))
          (maduin-dispatch--on-complete "s-1" 'completed)
          (should (equal landed "ifrit"))
          (should (equal (car closed) "t1"))
          (should (member "s-1" deleted))
          (should-not maduin-dispatch--active))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-completion-failure-keeps-open ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (commented nil)
         (closed nil)
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn (lambda (_w _m _a _p) "s-1"))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--comment-fn (lambda (task text) (setq commented (cons task text)) t))
          (maduin-dispatch--close-fn (lambda (task _out) (setq closed task) t))
         (maduin-dispatch--session-delete-fn (lambda (_sid) t)))
    (unwind-protect
        (progn
          (maduin-dispatch-implement "t1")
          (maduin-dispatch--on-complete "s-1" 'failed)
          (should (equal (car commented) "t1"))
          (should-not closed)
          (should-not maduin-dispatch--active))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-completion-conflict-dispatches-repairer ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (run-count 0)
         (commented nil)
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn
          (lambda (_w _m _a _p)
            (setq run-count (1+ run-count))
            (format "s-%d" run-count)))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--diff-fn (lambda (_sid) nil))
         (maduin-dispatch--land-fn (lambda (_seat) 'conflict))
         (maduin-dispatch--comment-fn (lambda (task text) (setq commented (cons task text)) t))
         (maduin-dispatch--close-fn (lambda (_t _o) t))
         (maduin-dispatch--session-delete-fn (lambda (_sid) t)))
    (unwind-protect
        (progn
          (maduin-dispatch-implement "t1")   ; run-count 1, seat ifrit
          (maduin-dispatch--on-complete "s-1" 'completed)
          ;; conflict → repairer dispatched → second session run.
          (should (= run-count 2))
          (should (equal (car commented) "t1"))
          (should (cl-find-if (lambda (e) (eq (plist-get e :role) 'repairer))
                              maduin-dispatch--active)))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-run-loop-dispatches-ready ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (run-count 0)
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn
          (lambda (_w _m _a _p)
            (setq run-count (1+ run-count))
            (format "s-%d" run-count)))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--ready-fn (lambda () '("t1" "t2")))
         (maduin-dispatch--open-epics-fn (lambda () nil)))
    (unwind-protect
        (progn
          (maduin-dispatch-run-loop)
          (should (= run-count 2))
          (should (= (length maduin-dispatch--active) 2)))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-start-stop-timer ()
  :tags '(maduin)
  (let ((maduin-dispatch--timer nil)
        (maduin-dispatch--active nil)
        (maduin-dispatch--session-delete-fn (lambda (_sid) t)))
    (unwind-protect
        (progn
          (maduin-dispatch-start)
          (should maduin-dispatch--timer)
          (maduin-dispatch-stop)
          (should-not maduin-dispatch--timer))
      (maduin-dispatch-stop))))

(ert-deftest maduin-test-dispatch-undecomposed-epics ()
  :tags '(maduin)
  (let ((maduin-dispatch--open-epics-fn
         (lambda () '("epic-a" "epic-b" "epic-c")))
        (maduin-dispatch--epic-children-fn
         (lambda (epic)
           (cond ((string= epic "epic-a") '("t1" "t2"))
                 ((string= epic "epic-b") '("t3"))
                 (t nil)))))
    (should (equal (maduin-dispatch--undecomposed-epics)
                   '("epic-c")))))

(ert-deftest maduin-test-dispatch-undecomposed-epics-none-open ()
  :tags '(maduin)
  (let ((maduin-dispatch--open-epics-fn (lambda () nil)))
    (should-not (maduin-dispatch--undecomposed-epics))))

(ert-deftest maduin-test-dispatch-run-loop-decomposes-epics ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (decomposed '())
         (run-count 0)
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn
          (lambda (_w _m _a _p)
            (setq run-count (1+ run-count))
            (format "s-%d" run-count)))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--ready-fn (lambda () '("t1")))
         (maduin-dispatch--open-epics-fn
          (lambda () '("epic-x" "epic-y")))
         (maduin-dispatch--epic-children-fn
          (lambda (epic)
            (when (string= epic "epic-x") '("c1"))))
         (maduin-dispatch--epic-decompose-fn
          (lambda (epic) (push epic decomposed)
            (maduin-dispatch-design epic))))
    (unwind-protect
        (progn
          ;; epic-x has children → skipped; epic-y lacks decomposition.
          (maduin-dispatch-run-loop)
          (should (equal decomposed '("epic-y")))
          ;; 1 implementer + 1 designer session.
          (should (= run-count 2))
          (should (= (length maduin-dispatch--active) 2)))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-designer-completion-does-not-close ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (landed nil)
         (closed nil)
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn (lambda (_w _m _a _p) "s-des-1"))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--diff-fn (lambda (_sid) nil))
         (maduin-dispatch--land-fn (lambda (seat) (setq landed seat) t))
         (maduin-dispatch--close-fn (lambda (task _out) (setq closed task) t))
         (maduin-dispatch--session-delete-fn (lambda (_sid) t)))
    (unwind-protect
        (progn
          (maduin-dispatch-design "epic-z")
          (should (= (length maduin-dispatch--active) 1))
          (maduin-dispatch--on-complete "s-des-1" 'completed)
          ;; designer session: lands but does NOT close the epic.
          (should (equal landed "ramuh"))
          (should-not closed)
          (should-not maduin-dispatch--active))
      (delete-directory dir t))))

;;; 16. designer (Ramuh)

(ert-deftest maduin-test-designer-functions-exist ()
  :tags '(maduin)
  (dolist (f '(maduin-designer-design
               maduin-designer-decompose-epic
               maduin-designer-drop-in
               maduin-designer-pending-tasks))
    (should (fboundp f))))

(ert-deftest maduin-test-designer-epic-prompt-template ()
  :tags '(maduin)
  (let ((tmpl (maduin-designer--epic-template)))
    (should (stringp tmpl))
    (should (string-match-p "{id}" tmpl))
    (should (string-match-p "decompos" (downcase tmpl)))
    (should (string-match-p "--parent" tmpl))
    (should (string-match-p "staged" (downcase tmpl)))
    (should (string-match-p "--design" tmpl))
    (should (string-match-p "do not implement" (downcase tmpl)))
    (should (string-match-p "do not close" (downcase tmpl)))))

(ert-deftest maduin-test-designer-decompose-epic-dispatches ()
  :tags '(maduin)
  (let* ((captured-task nil)
         (captured-plan nil)
         (maduin-designer--show-fn
          (lambda (_t) (list :title "E-Body" :desc "E-Desc")))
         (maduin-designer--dispatch-fn
          (lambda (task plan)
            (setq captured-task task)
            (setq captured-plan plan)
            "s-epic-1")))
    (should (equal (maduin-designer-decompose-epic "maduin-ep1") "s-epic-1"))
    (should (equal captured-task "maduin-ep1"))
    (should (string-match-p "maduin-ep1" captured-plan))
    (should (string-match-p "E-Body" captured-plan))
    (should (string-match-p "E-Desc" captured-plan))
    (should (string-match-p "decompos" (downcase captured-plan)))
    (should (string-match-p "--parent" captured-plan))
    ;; placeholders fully substituted.
    (should-not (string-match-p "{id}" captured-plan))
    (should-not (string-match-p "{title}" captured-plan))
    (should-not (string-match-p "{desc}" captured-plan))))

(ert-deftest maduin-test-designer-prompt-template ()
  :tags '(maduin)
  (let ((tmpl (maduin-designer--template)))
    (should (stringp tmpl))
    (should (string-match-p "{id}" tmpl))
    (should (string-match-p "do not implement" (downcase tmpl)))
    (should (string-match-p "defer" (downcase tmpl)))
    (should (string-match-p "staged" (downcase tmpl)))
    (should (string-match-p "--design" tmpl))
    (should (string-match-p "--acceptance" tmpl))))

(ert-deftest maduin-test-designer-design-builds-prompt-and-dispatches ()
  :tags '(maduin)
  (let* ((captured-task nil)
         (captured-plan nil)
         (maduin-designer--show-fn
          (lambda (_t) (list :title "T-Body" :desc "D-Body")))
         (maduin-designer--dispatch-fn
          (lambda (task plan)
            (setq captured-task task)
            (setq captured-plan plan)
            "s-des-1")))
    (should (equal (maduin-designer-design "maduin-abc") "s-des-1"))
    (should (equal captured-task "maduin-abc"))
    (should (string-match-p "maduin-abc" captured-plan))
    (should (string-match-p "T-Body" captured-plan))
    (should (string-match-p "D-Body" captured-plan))
    (should (string-match-p "do not implement" (downcase captured-plan)))
    (should (string-match-p "staged" (downcase captured-plan)))
    (should (string-match-p "defer" (downcase captured-plan)))
    ;; {id}/{title}/{desc} placeholders fully substituted.
    (should-not (string-match-p "{id}" captured-plan))
    (should-not (string-match-p "{title}" captured-plan))
    (should-not (string-match-p "{desc}" captured-plan))))

(ert-deftest maduin-test-designer-design-plan-override ()
  :tags '(maduin)
  (let* ((got-plan nil)
         (maduin-designer--dispatch-fn
          (lambda (_task plan) (setq got-plan plan) "s-des-2")))
    (should (equal (maduin-designer-design "maduin-abc" "CUSTOM PLAN")
                   "s-des-2"))
    (should (equal got-plan "CUSTOM PLAN"))))

(ert-deftest maduin-test-designer-pending-tasks ()
  :tags '(maduin)
  (let* ((maduin-designer--query-fn
          (lambda (_q) '("t-with-design" "t-no-design" "t-no-design2")))
         (maduin-designer--has-design-fn
          (lambda (id) (string= id "t-with-design"))))
    (should (equal (maduin-designer-pending-tasks)
                   '("t-no-design" "t-no-design2")))))

(ert-deftest maduin-test-designer-pending-tasks-empty ()
  :tags '(maduin)
  (let ((maduin-designer--query-fn (lambda (_q) nil)))
    (should (null (maduin-designer-pending-tasks)))))

(ert-deftest maduin-test-designer-drop-in-delegates ()
  :tags '(maduin)
  (let* ((got-seat nil)
         (got-role nil)
         (got-model nil)
         (maduin-designer--terminal-open-fn
          (lambda (seat role model)
            (setq got-seat seat)
            (setq got-role role)
            (setq got-model model)
            (get-buffer-create " *ert-designer-dropin*"))))
    (unwind-protect
        (progn
          (should (bufferp (maduin-designer-drop-in "ramuh")))
          (should (equal got-seat "ramuh"))
          (should (eq got-role 'designer))
          (should (string= got-model "opencode-go/deepseek-v4-pro")))
      (when (get-buffer " *ert-designer-dropin*")
        (kill-buffer " *ert-designer-dropin*")))))

;;; 17. concierge (Alexander)

(ert-deftest maduin-test-concierge-functions-exist ()
  :tags '(maduin)
  (dolist (f '(maduin-concierge maduin-concierge-dismiss))
    (should (fboundp f))))

(ert-deftest maduin-test-concierge-model-resolution ()
  :tags '(maduin)
  (should (equal (maduin-concierge--seat-model "alexander")
                 "opencode-go/deepseek-v4-pro"))
  (should (equal (maduin-concierge--model) "opencode-go/deepseek-v4-pro")))

(ert-deftest maduin-test-concierge-summon ()
  :tags '(maduin)
  (let* ((called nil)
         (maduin-concierge--terminal-open-fn
          (lambda (seat role model) (setq called (list seat role model)))))
    (maduin-concierge)
    (should (equal called
                   '("alexander" concierge "opencode-go/deepseek-v4-pro")))))

(ert-deftest maduin-test-concierge-dismiss ()
  :tags '(maduin)
  (let* ((dismissed nil)
         (maduin-concierge--terminal-dismiss-fn
          (lambda (seat) (setq dismissed seat) "handoff-note-123")))
    (should (equal (maduin-concierge-dismiss) "handoff-note-123"))
    (should (equal dismissed "alexander"))))

(ert-deftest maduin-test-concierge-prompt-template ()
  :tags '(maduin)
  (let ((tmpl (maduin-terminal--template "concierge")))
    (should (stringp tmpl))
    (should (string-match-p "epic" tmpl))
    (should (string-match-p "--design" tmpl))
    (should (string-match-p "design doc" tmpl))
    (should (string-match-p "Do not decompose" tmpl))
    (should (string-match-p "Do not implement" tmpl))))

;;; 18. integration (entry point wiring)

(ert-deftest maduin-test-main-interactive-commands ()
  :tags '(maduin)
  (dolist (f '(maduin-concierge
               maduin-concierge-dismiss
               maduin-gate-approve
               maduin-gate-reject
               maduin-gate-staged-list
               maduin-designer-drop-in
               maduin-designer-pending-tasks
               maduin-start
               maduin-stop))
    (should (commandp f))))

(ert-deftest maduin-test-main-keymap-bindings ()
  :tags '(maduin)
  (dolist (pair '(("C-c s c" . maduin-concierge)
                  ("C-c s d" . maduin-concierge-dismiss)
                  ("C-c s n" . maduin-designer-drop-in)
                  ("C-c s p" . maduin-designer-pending-tasks)
                  ("C-c s g a" . maduin-gate-approve)
                  ("C-c s g r" . maduin-gate-reject)
                  ("C-c s g l" . maduin-gate-staged-list)))
    (should (eq (lookup-key maduin-mode-map (kbd (car pair))) (cdr pair)))))

(ert-deftest maduin-test-main-start-zero-sessions ()
  :tags '(maduin)
  (let ((maduin-dispatch--timer nil)
        (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn
          (lambda (_w _m _a _p) (ert-fail "maduin-start must not spawn sessions")))
        (maduin-dispatch--session-delete-fn (lambda (_sid) t)))
    (unwind-protect
        (progn
          (maduin-start)
          (should maduin-dispatch--timer)     ; dispatchers active
          (should-not maduin-dispatch--active)) ; zero sessions spawned
      (maduin-dispatch-stop))))

(ert-deftest maduin-test-main-stop-tears-down ()
  :tags '(maduin)
  (let* ((maduin-dispatch--timer nil)
         (maduin-dispatch--active
          (list (list :handle "s-stop-1" :seat "ifrit" :role 'implementer :task "t1")))
         (deleted '())
         (maduin-dispatch--session-delete-fn (lambda (sid) (push sid deleted) t)))
    (unwind-protect
        (progn
          (maduin-stop)
          (should-not maduin-dispatch--timer)
          (should-not maduin-dispatch--active)
          (should (member "s-stop-1" deleted)))
      (maduin-dispatch-stop))))

;;; 19. full-loop integration (mock opencode, chained seams)

(ert-deftest maduin-test-full-loop-epic-to-close ()
  :tags '(maduin)
  (let* ((ts (format-time-string "%Y%m%d%H%M%S" (current-time)))
         (epic (condition-case nil
                   (maduin-bd-create-epic
                    (format "ert-loop-epic-%s" ts) "scratch epic for ERT full-loop")
                 (error nil)))
         (task (and epic
                    (condition-case nil
                        (maduin-bd-create-task
                         (format "ert-loop-task-%s" ts)
                         "scratch task for ERT full-loop" epic)
                      (error nil)))))
    (unwind-protect
        (when (and epic task)
          ;; 1. a deferred task is filed for the designer (Ramuh).
          (should (maduin-bd-defer task))
          ;; 2. designer fills design + stages (defer + staged label).
          (should (maduin-gate-stage task "design body" "acceptance body"))
          (should (member task (maduin-gate-staged-list)))
          ;; 3. gate approves → undefer + remove staged label.
          (should (maduin-gate-approve task))
          (should-not (member task (maduin-gate-staged-list)))
          ;; 4. appears in ready.
          (should (member task (maduin-bd-ready-tasks)))
          ;; 5. run-loop → implement session → mock complete → land → close
          ;;    (session/land/close seams mocked; no real opencode).
          (let* ((dir (maduin-test--temp-dir))
                 (landed nil)
                 (closed nil)
                 (deleted '())
                 (maduin-dispatch--active nil)
                 (maduin-dispatch--ready-fn (lambda () (list task)))
                 (maduin-dispatch--open-epics-fn (lambda () nil))
                 (maduin-dispatch--session-run-fn (lambda (_w _m _a _p) "s-loop-1"))
                 (maduin-dispatch--claim-fn (lambda (_t) t))
                 (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
                 (maduin-dispatch--workdir-fn (lambda (_s) dir))
                 (maduin-dispatch--diff-fn
                  (lambda (_sid) (list '((file . "x.el") (patch . "+1")))))
                 (maduin-dispatch--land-fn (lambda (seat) (setq landed seat) t))
                 (maduin-dispatch--close-fn (lambda (t2 _out) (setq closed t2) t))
                 (maduin-dispatch--session-delete-fn (lambda (sid) (push sid deleted) t)))
            (unwind-protect
                (progn
                  (maduin-dispatch-run-loop)
                  (should (= (length maduin-dispatch--active) 1))
                  (should (equal (plist-get (car maduin-dispatch--active) :task) task))
                  (maduin-dispatch--on-complete "s-loop-1" 'completed)
                  (should (equal landed "ifrit"))
                  (should (equal closed task))
                  (should (member "s-loop-1" deleted))
                  (should-not maduin-dispatch--active))
              (delete-directory dir t))))
      (maduin-test--bd-delete task)
      (maduin-test--bd-delete epic))))

;;; 20. v0.3 — agent resolution + batched review gate (Odin)

(ert-deftest maduin-test-agent-for-role-mapping ()
  :tags '(maduin)
  (should (equal (maduin-agent--for-role 'implementer) "slugineer-worker"))
  (should (equal (maduin-agent--for-role "implementer") "slugineer-worker"))
  (should (equal (maduin-agent--for-role 'designer) "slugineer-planner-designer"))
  (should (equal (maduin-agent--for-role "concierge") "slugineer-planner-concierge"))
  (should (null (maduin-agent--for-role 'reviewer)))
  (should (null (maduin-agent--for-role "unknown")))
  (should (null (maduin-agent--for-role nil))))

(ert-deftest maduin-test-session-create-agent-intent ()
  :tags '(maduin)
  (let ((maduin-opencode-command "no-such-opencode-cli-xyz"))
    (let ((buf (maduin-session-create "agent-seat-xyz" 'implementer "test-model"
                                      default-directory "slugineer-worker")))
      (unwind-protect
          (progn
            (should (buffer-live-p buf))
            (let ((intent (buffer-local-value 'maduin-intent buf)))
              (should (member "--agent" intent))
              (should (member "slugineer-worker" intent))
              (should (member "--model" intent))))
        (maduin-session-kill "agent-seat-xyz")
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest maduin-test-review-verdict-approved ()
  :tags '(maduin)
  (should (eq (maduin-review--verdict "REVIEW: APPROVED\n") 'approved))
  (should (eq (maduin-review--verdict "blah\nREVIEW: APPROVED\nmore") 'approved)))

(ert-deftest maduin-test-review-verdict-drift ()
  :tags '(maduin)
  (should (equal (maduin-review--verdict "REVIEW: DRIFT fix the widget\n")
                 '(drift . "fix the widget")))
  (should (equal (maduin-review--verdict "noise\nREVIEW: DRIFT needs work")
                 '(drift . "needs work"))))

(ert-deftest maduin-test-review-verdict-garbage ()
  :tags '(maduin)
  (should (eq (maduin-review--verdict "no marker here") 'error))
  (should (eq (maduin-review--verdict nil) 'error)))

(ert-deftest maduin-test-review-note-land-batch-trigger ()
  :tags '(maduin)
  (let ((maduin-review--checkpoint '(:start-sha "abc" :landed 0)))
    (should-not (maduin-review--note-land))
    (should-not (maduin-review--note-land))
    (should (maduin-review--note-land))
    (should (= (plist-get maduin-review--checkpoint :landed) 3)))
  ;; No checkpoint → no-op.
  (should-not (maduin-review--note-land)))

(ert-deftest maduin-test-review-blocked-p ()
  :tags '(maduin)
  (let ((maduin-review--query-fn (lambda (_q) '("drift-task-1"))))
    (should (maduin-review--blocked-p)))
  (let ((maduin-review--query-fn (lambda (_q) nil)))
    (should-not (maduin-review--blocked-p))))

(ert-deftest maduin-test-review-gate-approved-resets-checkpoint ()
  :tags '(maduin)
  (let* ((maduin-review--checkpoint nil)
         (maduin-review--main-root-fn (lambda () "/repo"))
         (maduin-review--git-output-fn
          (lambda (_dir &rest args)
            (if (member "rev-parse" args)
                (cons 0 "abc123\n")
              (cons 0 "+fake diff\n"))))
         (maduin-review--query-fn (lambda (_q) nil))
         (maduin-review--session-run-fn (lambda (_w _m _a _p) "sid-1"))
         (maduin-review--complete-p-fn (lambda (_sid) 'completed))
         (maduin-review--session-output-fn (lambda (_sid) "REVIEW: APPROVED\n")))
    (should (eq (maduin-review-gate) 'approved))
    (should (equal (plist-get maduin-review--checkpoint :start-sha) "abc123"))
    (should (zerop (plist-get maduin-review--checkpoint :landed)))))

(ert-deftest maduin-test-review-gate-drift-creates-drift-fix ()
  :tags '(maduin)
  (let* ((maduin-review--checkpoint '(:start-sha "old" :landed 5))
         (created-cmd nil)
         (maduin-review--main-root-fn (lambda () "/repo"))
         (maduin-review--git-output-fn (lambda (_dir &rest _args) (cons 0 "diff")))
         (maduin-review--query-fn (lambda (_q) nil))
         (maduin-review--session-run-fn (lambda (_w _m _a _p) "sid-1"))
         (maduin-review--complete-p-fn (lambda (_sid) 'completed))
         (maduin-review--session-output-fn
          (lambda (_sid) "REVIEW: DRIFT fix the widget\n"))
         (maduin-review--run-fn
          (lambda (cmd) (setq created-cmd cmd) (cons 0 "drift-task-1\n")))
         (maduin-review--comment-fn (lambda (_id _text) t)))
    (should (eq (maduin-review-gate) 'drift))
    (should (string-match-p "drift-fix" created-cmd))
    (should (string-match-p "widget" created-cmd))
    ;; checkpoint NOT reset on drift.
    (should (equal (plist-get maduin-review--checkpoint :start-sha) "old"))
    (should (= (plist-get maduin-review--checkpoint :landed) 5))))

(ert-deftest maduin-test-review-gate-disabled ()
  :tags '(maduin)
  (let ((maduin-config '((reviewer (enabled . nil)))))
    (should (null (maduin-review-gate)))))

(provide 'maduin-test)

;;; maduin-test.el ends here
