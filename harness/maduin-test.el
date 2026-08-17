;;; maduin-test.el --- ERT tests for all harness components  -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT 測試覆蓋 harness 各組件：config、bd-bridge、session、
;; handoff、pipeline、cockpit、main。全部標記
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
(require 'maduin-session)
(require 'maduin-handoff)
(require 'maduin-pipeline)
(require 'maduin-cockpit)
(require 'maduin-review)
(require 'maduin-terminal)
(require 'maduin-dispatch)
(require 'maduin-designer)
(require 'maduin-concierge)

;;; Helpers

(defun maduin-test--temp-dir ()
  "Return a new temporary directory path."
  (make-temp-file "sh-test-" t))

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
  (should (equal (maduin--seat-model "ifrit") "opencode/deepseek-v4-flash-free"))
  (should (equal (maduin--seat-model "shiva") "opencode/deepseek-v4-flash-free"))
  (should (equal (maduin--seat-model "titan") "opencode/deepseek-v4-flash-free")))

(ert-deftest maduin-test-config-fleet-fallback ()
  :tags '(maduin)
  (should (equal (maduin-dispatch--seat-fallback 'implementer)
                 "opencode-go/deepseek-v4-flash"))
  (should-not (maduin-dispatch--seat-fallback 'designer)))

(ert-deftest maduin-test-config-poll-interval ()
  :tags '(maduin)
  (let ((fleet (cdr (assq 'fleet maduin-config))))
    (should (= (alist-get 'poll-interval fleet) 30))))

;;; 3. bd-bridge

(ert-deftest maduin-test-bd-json-data-array ()
  :tags '(maduin)
  (should (equal (maduin-bd--json-data "[{\"id\":\"t1\"}]")
                 '(((id . "t1"))))))

(ert-deftest maduin-test-bd-json-data-non-json ()
  :tags '(maduin)
  (should-not (maduin-bd--json-data "Error: no issue")))

(ert-deftest maduin-test-bd-json-data-empty ()
  :tags '(maduin)
  (should-not (maduin-bd--json-data ""))
  (should-not (maduin-bd--json-data nil)))

(ert-deftest maduin-test-bd-json-data-object ()
  :tags '(maduin)
  (should-not (maduin-bd--json-data "{\"error\":\"x\"}")))

(ert-deftest maduin-test-bd-bridge-functions-exist ()
  :tags '(maduin)
  (dolist (f '(maduin-bd--call
               maduin-bd-list-all
               maduin-bd-ready-tasks
               maduin-bd-claim
               maduin-bd-release
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

(ert-deftest maduin-test-bd-close-path ()
  :tags '(maduin)
  (let ((maduin-bd-close-file "out.md"))
    (should (string= (maduin-bd-close-path "/x/y") "/x/y/out.md"))
    (should (string= (maduin-bd-close-path nil)
                     (expand-file-name "out.md" default-directory)))))

(ert-deftest maduin-test-bd-close-writes-to-worktree-not-root ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (maduin-bd-close-file (format "ert-close-%d.md" (random)))
         (root-file (expand-file-name maduin-bd-close-file default-directory)))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'maduin-bd--run)
                     (lambda (_cmd) (cons 0 ""))))
            (should (maduin-bd-close "t1" "out" dir)))
          ;; Written inside DIR (the worktree), NOT the repo/harness root.
          (should (string= (with-temp-buffer
                             (insert-file-contents
                              (expand-file-name maduin-bd-close-file dir))
                             (buffer-string))
                           "out"))
          (should-not (file-exists-p root-file)))
      (delete-directory dir t))))

(ert-deftest maduin-test-bd-close-default-dir-fallback ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (maduin-bd-close-file (format "ert-close2-%d.md" (random)))
         (file (expand-file-name maduin-bd-close-file dir)))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'maduin-bd--run) (lambda (_cmd) (cons 0 "")))
                    (default-directory dir))
            (should (maduin-bd-close "t2" nil)))
          (should (file-exists-p file)))
      (delete-directory dir t))))

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

(ert-deftest maduin-test-bd-query-all-flag ()
  :tags '(maduin)
  ;; Default excludes closed; ALL=t must append `--all' so closed children
  ;; are visible (an epic with only-closed children still reports them).
  (let ((seen nil))
    (cl-letf (((symbol-function 'maduin-bd--call)
               (lambda (_prog &rest args)
                 (setq seen args)
                 (cons 0 "[{\"id\":\"t1\"}]"))))
      (should (equal (maduin-bd-query "parent=epic-x") '("t1")))
      (should (member "--json" seen))
      (should-not (member "--all" seen)))
    (cl-letf (((symbol-function 'maduin-bd--call)
               (lambda (_prog &rest args)
                 (setq seen args)
                 (cons 0 "[{\"id\":\"t1\"}]"))))
      (should (equal (maduin-bd-query "parent=epic-x" t) '("t1")))
      (should (member "--all" seen)))))

(ert-deftest maduin-test-bd-epic-children-includes-closed ()
  :tags '(maduin)
  ;; Epic-children MUST include closed children (`--all'), else a done epic
  ;; looks undecomposed and Ramuh re-dispatches decomposition on it.
  (let ((seen nil))
    (cl-letf (((symbol-function 'maduin-bd--call)
               (lambda (_prog &rest args)
                 (setq seen args)
                 (cons 0 "[{\"id\":\"c1\"},{\"id\":\"c2\"}]"))))
      (should (equal (maduin-bd-epic-children "epic-x") '("c1" "c2")))
      (should (member "parent=epic-x" seen))
      (should (member "--all" seen)))))

(ert-deftest maduin-test-bd-call-task-id-as-arg-no-shell ()
  :tags '(maduin)
  ;; maduin-bd--call must hand task-ids to the program as literal arg
  ;; elements (a Lisp list), never interpolated into a shell string, so
  ;; quoting/injection is impossible.  Mock `call-process' to capture the
  ;; exact program and args.
  (let (seen)
    (cl-letf (((symbol-function 'call-process)
               (lambda (program _infile _destination _display &rest args)
                 (setq seen (cons program args))
                 0)))
      (maduin-bd-show "maduin-x59.1")
      (should (equal (car seen) "bd"))
      (should (cl-every #'stringp (cdr seen)))
      (should (member "show" (cdr seen)))
      (should (member "--json" (cdr seen)))
      ;; The task-id arrives as a single argument element, exactly equal.
      (should (member "maduin-x59.1" (cdr seen)))
      (should-not (string-match-p "maduin-x59.1"
                                  (mapconcat #'identity (remove "maduin-x59.1" (cdr seen)) " "))))))

(ert-deftest maduin-test-bd-call-real-program-no-shell ()
  :tags '(maduin)
  ;; maduin-bd--call must run the program directly (no shell): each arg
  ;; arrives verbatim as one element, and shell metacharacters inside an
  ;; arg are inert.  Real subprocess via `call-process', exit+stdout shape
  ;; asserted.  Skips when printf is unavailable (unlikely on macOS/Linux).
  (let ((printf (executable-find "printf")))
    (skip-unless printf)
    (let* ((task-id "maduin-x59.1")
           (toxic "evil; echo hacked >&2 |$(touch pwn)`date` &")
           (args (list "%s\n" task-id toxic))
           (res (apply #'maduin-bd--call printf args)))
      (should (= 0 (car res)))
      (should (stringp (cdr res)))
      ;; One output line per arg, in order, byte-for-byte — proves args
      ;; were handed to the program as list elements, never shell-joined.
      (let ((lines (split-string (cdr res) "\n" t)))
        (should (equal lines (list task-id toxic)))))))

(ert-deftest maduin-test-bd-list-all-single-call-normalized ()
  :tags '(maduin)
  ;; One `bd list --json --all' subprocess yields normalized bead alists —
  ;; callers count statuses client-side instead of 3x `bd count --status'.
  (let ((seen nil))
    (cl-letf (((symbol-function 'maduin-bd--call)
               (lambda (_prog &rest args)
                 (setq seen args)
                 (cons 0 "[{\"id\":\"a\",\"status\":\"closed\"}]"))))
      (should (equal (maduin-bd-list-all)
                     '(((id . "a") (status . "closed"))))))
    (should (equal seen '("list" "--json" "--all")))))

(ert-deftest maduin-test-bd-list-all-failure-nil ()
  :tags '(maduin)
  (cl-letf (((symbol-function 'maduin-bd--call)
             (lambda (&rest _) (cons 1 "boom"))))
    (should-not (maduin-bd-list-all))))

(ert-deftest maduin-test-bd-release-resets-status-open ()
  :tags '(maduin)
  ;; Releasing a claim must reset status to open (bd update ID --status open).
  (let ((seen nil))
    (cl-letf (((symbol-function 'maduin-bd--run)
               (lambda (cmd)
                 (setq seen cmd)
                 (cons 0 ""))))
      (should (maduin-bd-release "t1"))
      (should (string-match-p "t1" seen))
      (should (string-match-p "--status open" seen)))))

;;; 4. autonomous session substrate (opencode run + NDJSON)

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

(ert-deftest maduin-test-session-usage-limit-line ()
  :tags '(maduin)
  (should (maduin-session--usage-limit-line-p
           "{\"type\":\"message.updated\",\"info\":{\"error\":{\"name\":\"APIError\",\"data\":{\"statusCode\":429,\"message\":\"usage limit exceeded\"}}}}"))
  (should (maduin-session--usage-limit-line-p
           "{\"type\":\"session.error\",\"error\":\"rate limit reached\"}"))
  (should (maduin-session--usage-limit-line-p
           "{\"type\":\"message.updated\",\"info\":{\"error\":{\"data\":{\"message\":\"429 Too Many Requests\"}}}}"))
  ;; Model text mentioning 429/error in ordinary output is NOT a limit.
  (should-not (maduin-session--usage-limit-line-p
               "{\"type\":\"text\",\"part\":{\"type\":\"text\",\"text\":\"handle HTTP 429 error responses\"}}"))
  ;; Bare failure with no usage/limit signal is NOT a limit.
  (should-not (maduin-session--usage-limit-line-p
               "{\"type\":\"step_finish\",\"part\":{\"reason\":\"error\"}}")))

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

(ert-deftest maduin-test-pipeline-fleet-busy-dispatch ()
  :tags '(maduin)
  ;; Fleet busy must read the dispatch active registry (demand-driven
  ;; source of truth), not legacy seat-buffer sessions.
  (let ((maduin-dispatch--active
         '((:handle "h1" :seat "ifrit" :role implementer :task "bd-1")
           (:handle "h2" :seat "shiva" :role designer :task "bd-2"))))
    (should (= (maduin-pipeline--fleet-busy-count) 1)))
  (let ((maduin-dispatch--active nil))
    (should (= (maduin-pipeline--fleet-busy-count) 0))))

(ert-deftest maduin-test-pipeline-count-statuses-client-side ()
  :tags '(maduin)
  ;; Fixture alists → correct counts, no bd subprocesses.  Status matches
  ;; bd's stored status strings (underscore: in_progress), which is what
  ;; `bd list --json --all' emits.
  (let ((data (list (list (cons 'status "closed") (cons 'id "c1"))
                    (list (cons 'status "in_progress") (cons 'id "i1"))
                    (list (cons 'status "blocked") (cons 'id "b1"))
                    (list (cons 'status "closed") (cons 'id "c2"))
                    (list (cons 'status "open") (cons 'id "o1"))
                    (list (cons 'status "deferred") (cons 'id "d1")))))
    (should (= (maduin-pipeline--count data "closed") 2))
    (should (= (maduin-pipeline--count data "in_progress") 1))
    (should (= (maduin-pipeline--count data "blocked") 1))
    (should (= (maduin-pipeline--count data "open") 1))
    (should (= (maduin-pipeline--count data "deferred") 1))
    (should (= (maduin-pipeline--count data "queued") 0)))
  ;; Nil data (failed list call) counts as zero.
  (should (= (maduin-pipeline--count nil "closed") 0)))

(ert-deftest maduin-test-pipeline-status-at-most-two-bd-calls ()
  :tags '(maduin)
  ;; One refresh = `bd ready' + one `bd list --json --all' (≤ 2 calls),
  ;; statuses derived client-side from the list result's status field.
  (let ((calls 0))
    (cl-letf (((symbol-function 'maduin-bd--call)
               (lambda (_prog &rest args)
                 (cl-incf calls)
                 (if (member "ready" args)
                     (cons 0 "[{\"id\":\"q1\"},{\"id\":\"q2\"}]")
                   (cons 0 "[{\"id\":\"c1\",\"status\":\"closed\"},
                             {\"id\":\"c2\",\"status\":\"closed\"},
                             {\"id\":\"i1\",\"status\":\"in_progress\"},
                             {\"id\":\"b1\",\"status\":\"blocked\"}]"))))
              ((symbol-value 'maduin-dispatch--active) nil))
      (let ((st (maduin-pipeline-status)))
        (should (<= calls 2))
        (should (= (plist-get st :queued) 2))
        (should (= (plist-get st :active) 1))
        (should (= (plist-get st :completed) 2))
        (should (= (plist-get st :blocked) 1))))))

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

(ert-deftest maduin-test-cockpit-refresh-interval-bound ()
  :tags '(maduin)
  (should (integerp maduin-cockpit-refresh-interval))
  (should (> maduin-cockpit-refresh-interval 0)))

(ert-deftest maduin-test-cockpit-timer-start-stop ()
  :tags '(maduin)
  (unwind-protect
      (progn
        (maduin-cockpit--start-timer)
        (should maduin-cockpit--timer)
        (should (timerp maduin-cockpit--timer))
        ;; Idempotent: starting twice keeps one timer.
        (let ((t1 maduin-cockpit--timer))
          (maduin-cockpit--start-timer)
          (should (eq t1 maduin-cockpit--timer)))
        (maduin-cockpit--stop-timer)
        (should (null maduin-cockpit--timer)))
    (when maduin-cockpit--timer
      (cancel-timer maduin-cockpit--timer)
      (setq maduin-cockpit--timer nil))))

(ert-deftest maduin-test-cockpit-auto-refresh-cancels-when-hidden ()
  :tags '(maduin)
  ;; In batch (no windows) the buffer is never visible, so one tick must
  ;; cancel the timer instead of refreshing (prevents timer leak).
  (unwind-protect
      (progn
        (maduin-cockpit--start-timer)
        (maduin-cockpit--auto-refresh)
        (should (null maduin-cockpit--timer)))
    (when maduin-cockpit--timer
      (cancel-timer maduin-cockpit--timer)
      (setq maduin-cockpit--timer nil))))

;;; 8b. cockpit-face

(ert-deftest maduin-test-cockpit-face-state-face-known ()
  :tags '(maduin)
  (dolist (s '(dead idle working running repairing))
    (should (facep (maduin-cockpit-state-face s))))
  (should (null (maduin-cockpit-state-face 'unknown)))
  (should (null (maduin-cockpit-state-face nil))))

(ert-deftest maduin-test-cockpit-face-state-color-known ()
  :tags '(maduin)
  (dolist (s '(dead idle working running repairing))
    (let ((c (maduin-cockpit-state-color s)))
      (should (stringp c))
      (should (> (length c) 0))))
  (should (null (maduin-cockpit-state-color 'unknown)))
  (should (null (maduin-cockpit-state-color nil))))

(ert-deftest maduin-test-cockpit-face-chip-face-known ()
  :tags '(maduin)
  (dolist (k '(queued active completed blocked fleet-free fleet-busy))
    (should (facep (maduin-cockpit-chip-face k))))
  (should (null (maduin-cockpit-chip-face 'unknown))))

(ert-deftest maduin-test-cockpit-face-setup-creates-all ()
  :tags '(maduin)
  (maduin-cockpit-face-setup)
  (dolist (f maduin-cockpit-face--pill-faces)
    (should (facep f))))

(ert-deftest maduin-test-cockpit-face-adapt-batch-safe ()
  :tags '(maduin)
  (condition-case nil
      (progn (maduin-cockpit-face-adapt) (should t))
    (error (should nil))))

(ert-deftest maduin-test-cockpit-face-adapt-pill-box ()
  :tags '(maduin)
  (maduin-cockpit-face-adapt)
  (if (display-graphic-p)
      (dolist (f maduin-cockpit-face--pill-faces)
        (should (eq (face-attribute f :box nil 'default) t)))
    (should t)))

;;; 8c. cockpit-rich

(ert-deftest maduin-test-cockpit-seat-status-rich ()
  :tags '(maduin)
  (cl-letf (((symbol-value 'maduin-dispatch--active)
             (list (list :handle "s-1" :seat "ifrit" :role 'implementer :task "t1")))
            ((symbol-function 'maduin-bd--call)
             (lambda (_prog &rest _args) (cons 0 "[{\"title\": \"T1 title\"}]"))))
    (let ((st (maduin-cockpit--seat-status "ifrit")))
      (should (equal (plist-get st :seat) "ifrit"))
      (should (eq (plist-get st :role) 'implementer))
      (should (eq (plist-get st :status) 'working))      ; dispatch ⇒ working
      (should (equal (plist-get st :task-id) "t1"))
      (should (equal (plist-get st :task-title) "T1 title"))
      (should (null (plist-get st :model)))              ; dispatch entry has none
      (should (null (plist-get st :uptime)))
      (should (null (plist-get st :phase))))))

(ert-deftest maduin-test-cockpit-task-title-success ()
  :tags '(maduin)
  (setq maduin-cockpit--title-cache nil)
  (let ((calls 0))
    (cl-letf (((symbol-function 'maduin-bd--call)
               (lambda (&rest _args)
                 (cl-incf calls)
                 (cons 0 "[{\"title\": \"Big Title\"}]"))))
      (should (equal (maduin-cockpit--task-title "maduin-x") "Big Title"))
      (should (= calls 1))
      ;; Cache hit: second call must not re-run bd.
      (should (equal (maduin-cockpit--task-title "maduin-x") "Big Title"))
      (should (= calls 1))))
  (setq maduin-cockpit--title-cache nil))

(ert-deftest maduin-test-cockpit-task-title-object-shape ()
  :tags '(maduin)
  (setq maduin-cockpit--title-cache nil)
  (cl-letf (((symbol-function 'maduin-bd--call)
             (lambda (&rest _args) (cons 0 "{\"title\": \"Obj Title\"}"))))
    (should (equal (maduin-cockpit--task-title "maduin-z") "Obj Title")))
  (setq maduin-cockpit--title-cache nil))

(ert-deftest maduin-test-cockpit-task-title-failure ()
  :tags '(maduin)
  (setq maduin-cockpit--title-cache nil)
  (cl-letf (((symbol-function 'maduin-bd--call)
             (lambda (&rest _args) (cons 1 "error output"))))
    (should (null (maduin-cockpit--task-title "maduin-y"))))
  (setq maduin-cockpit--title-cache nil))

(ert-deftest maduin-test-cockpit-status-pill-known ()
  :tags '(maduin)
  (dolist (s '(dead idle working running repairing))
    (let ((pill (maduin-cockpit--status-pill s)))
      (should (string= pill (symbol-name s)))
      (should (eq (get-text-property 0 'face pill)
                  (maduin-cockpit-state-face s))))))

(ert-deftest maduin-test-cockpit-status-pill-unknown ()
  :tags '(maduin)
  (let ((pill (maduin-cockpit--status-pill 'mystery)))
    (should (string= pill "mystery"))
    (should (null (get-text-property 0 'face pill))))
  (let ((pill (maduin-cockpit--status-pill nil)))
    (should (string= pill "dead"))
    (should (null (get-text-property 0 'face pill)))))

(ert-deftest maduin-test-cockpit-pipeline-summary-chips ()
  :tags '(maduin)
  (let ((summary (maduin-cockpit--pipeline-summary)))
    (dolist (k '(queued active completed blocked fleet-free fleet-busy))
      (should (string-match-p (symbol-name k) summary))
      (let ((pos (string-match (symbol-name k) summary)))
        (should (facep (get-text-property pos 'face summary)))))))

(ert-deftest maduin-test-cockpit-refresh-format-7-columns ()
  :tags '(maduin)
  (let ((buf (get-buffer-create "*maduin-cockpit*")))
    (unwind-protect
        (with-current-buffer buf
          (tabulated-list-mode)
          (setq maduin-cockpit--title-cache (list (cons "stale" "old")))
          (maduin-cockpit-refresh)
          (should (= (length tabulated-list-format) 7))
          (should (equal (elt (aref tabulated-list-format 0) 0) "Seat"))
          (should (equal (elt (aref tabulated-list-format 1) 0) "Role"))
          (should (equal (elt (aref tabulated-list-format 2) 0) "Status"))
          (should (equal (elt (aref tabulated-list-format 3) 0) "Task"))
          (should (equal (elt (aref tabulated-list-format 4) 0) "Model"))
          (should (equal (elt (aref tabulated-list-format 5) 0) "Uptime(s)"))
          (should (equal (elt (aref tabulated-list-format 6) 0) "Activity"))
          (should (equal maduin-cockpit--title-cache
                         (list (cons "stale" "old")))))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-refresh-keeps-title-cache ()
  :tags '(maduin)
  ;; Repeated refreshes with unchanged dispatch entries must NOT re-run
  ;; bd show: the title cache persists across refreshes.
  (let ((buf (get-buffer-create "*maduin-cockpit*"))
        (calls 0)
        (maduin-dispatch--active
         (list (list :handle "s-1" :seat "ifrit" :role "implementer" :task "t1")
               (list :handle "s-2" :seat "shiva" :role "designer" :task "t2"))))
    (unwind-protect
        (cl-letf (((symbol-function 'maduin-bd--call)
                   (lambda (&rest args)
                     ;; Count only bd show title fetches; pipeline
                     ;; summary also calls bd ready/list.
                     (when (member "show" args) (cl-incf calls))
                     (cons 0 "[{\"title\": \"T\"}]"))))
          (with-current-buffer buf (tabulated-list-mode))
          (setq maduin-cockpit--title-cache nil)
          (maduin-cockpit-refresh)
          (should (= calls 2))                  ; one bd show per task id
          (should (= (length maduin-cockpit--title-cache) 2))
          (maduin-cockpit-refresh)
          (maduin-cockpit-refresh)
          (should (= calls 2))                  ; zero new bd show calls
          (should (= (length maduin-cockpit--title-cache) 2)))
      (kill-buffer buf)
      (setq maduin-cockpit--title-cache nil))))

;;; 8d. cockpit-live

(ert-deftest maduin-test-cockpit-live-refresh-hook-defined ()
  :tags '(maduin)
  (should (boundp 'maduin-cockpit-refresh-hook))
  (should (listp maduin-cockpit-refresh-hook)))

(ert-deftest maduin-test-cockpit-live-register-once ()
  :tags '(maduin)
  (maduin-cockpit--register-live-updates)
  (maduin-cockpit--register-live-updates)
  (should (memq #'maduin-cockpit--schedule-refresh maduin-cockpit-refresh-hook))
  (should (memq #'maduin-cockpit--on-complete maduin-session-on-complete-hook))
  (should (= (cl-count #'maduin-cockpit--schedule-refresh
                       maduin-cockpit-refresh-hook)
             1))
  (should (= (cl-count #'maduin-cockpit--on-complete
                       maduin-session-on-complete-hook)
             1)))

(ert-deftest maduin-test-cockpit-live-schedule-refresh-visible ()
  :tags '(maduin)
  ;; Visible cockpit buffer → schedule a single-shot idle timer.
  (let ((buf (get-buffer-create "*maduin-cockpit*"))
        (maduin-cockpit--idle-timer nil))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window) (lambda (_b _f) t)))
          (maduin-cockpit--schedule-refresh)
          (should (timerp maduin-cockpit--idle-timer)))
      (when (timerp maduin-cockpit--idle-timer)
        (cancel-timer maduin-cockpit--idle-timer))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-live-schedule-refresh-buried-noop ()
  :tags '(maduin)
  ;; Buried (hidden) cockpit buffer → no timer scheduled.
  (let ((buf (get-buffer-create "*maduin-cockpit*"))
        (maduin-cockpit--idle-timer nil))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window) (lambda (_b _f) nil)))
          (maduin-cockpit--schedule-refresh)
          (should (null maduin-cockpit--idle-timer)))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-live-schedule-refresh-absent-noop ()
  :tags '(maduin)
  ;; No cockpit buffer at all → no timer scheduled, no error.
  (let ((maduin-cockpit--idle-timer nil))
    (when (get-buffer "*maduin-cockpit*") (kill-buffer "*maduin-cockpit*"))
    (maduin-cockpit--schedule-refresh)
    (should (null maduin-cockpit--idle-timer))))

(ert-deftest maduin-test-cockpit-live-idle-refresh-visible-runs ()
  :tags '(maduin)
  ;; The idle-timer callback refreshes when the buffer is visible.
  (let ((buf (get-buffer-create "*maduin-cockpit*"))
        (count 0))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window) (lambda (_b _f) t))
                  ((symbol-function 'maduin-cockpit-refresh)
                   (lambda () (setq count (1+ count)))))
          (with-current-buffer buf (tabulated-list-mode))
          (maduin-cockpit--idle-refresh)
          (should (= count 1)))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-live-idle-refresh-buried-noop ()
  :tags '(maduin)
  (let ((buf (get-buffer-create "*maduin-cockpit*"))
        (count 0))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window) (lambda (_b _f) nil))
                  ((symbol-function 'maduin-cockpit-refresh)
                   (lambda () (setq count (1+ count)))))
          (maduin-cockpit--idle-refresh)
          (should (= count 0)))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-live-on-complete-runs-hook ()
  :tags '(maduin)
  (let* ((count 0)
         (maduin-cockpit-refresh-hook (list (lambda () (setq count (1+ count))))))
    (maduin-cockpit--on-complete "s-1" 'completed)
    (should (= count 1))))

(ert-deftest maduin-test-cockpit-live-on-window-change-selected ()
  :tags '(maduin)
  ;; Cockpit in the selected window → refresh hook runs.
  (let* ((buf (get-buffer-create "*maduin-cockpit*"))
         (orig (window-buffer (selected-window)))
         (count 0)
         (maduin-cockpit-refresh-hook (list (lambda () (setq count (1+ count))))))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buf)
          (maduin-cockpit--on-window-change)
          (should (= count 1)))
      (set-window-buffer (selected-window) orig)
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-live-on-window-change-not-selected ()
  :tags '(maduin)
  ;; Selected window shows another buffer → no refresh (cheap guard).
  (let* ((buf (get-buffer-create "*maduin-cockpit*"))
         (other (get-buffer-create "*maduin-cockpit-live-other*"))
         (count 0)
         (maduin-cockpit-refresh-hook (list (lambda () (setq count (1+ count))))))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) other)
          (maduin-cockpit--on-window-change)
          (should (= count 0)))
      (kill-buffer buf)
      (kill-buffer other))))

(ert-deftest maduin-test-dispatch-spawn-runs-cockpit-refresh-hook ()
  :tags '(maduin)
  ;; Spawn path nudge: dispatch fires the guarded refresh hook, no require.
  (let* ((dir (maduin-test--temp-dir))
         (count 0)
         (maduin-cockpit-refresh-hook (list (lambda () (setq count (1+ count)))))
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn (lambda (_w _m _a _p) "s-1"))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir)))
    (unwind-protect
        (progn
          (should (equal (maduin-dispatch-implement "t1") "s-1"))
          (should (= count 1)))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-on-complete-runs-cockpit-refresh-hook ()
  :tags '(maduin)
  ;; Removal path nudge: completion fires the guarded refresh hook.
  (let* ((dir (maduin-test--temp-dir))
         (count 0)
         (maduin-cockpit-refresh-hook (list (lambda () (setq count (1+ count)))))
         (maduin-dispatch--active
          (list (list :handle "s-1" :seat "ifrit" :role 'implementer :task "t1")))
         (maduin-dispatch--diff-fn (lambda (_sid) nil))
         (maduin-dispatch--land-fn (lambda (_seat) t))
         (maduin-dispatch--close-fn (lambda (_t _o &optional _dir) t))
         (maduin-dispatch--session-delete-fn (lambda (_sid) t)))
    (unwind-protect
        (progn
          (maduin-dispatch--on-complete "s-1" 'completed)
          (should (= count 1))
          (should-not maduin-dispatch--active))
      (delete-directory dir t))))

;;; 8e. cockpit-inbox (embedded chaplet inbox)

(ert-deftest maduin-test-cockpit-show-inbox-absent-still-renders ()
  :tags '(maduin)
  ;; chaplet absent → cockpit still renders, message issued, no error.
  (let ((msg nil))
    (unwind-protect
        (cl-letf (((symbol-function 'require)
                   (lambda (_feature &optional _na _ne) nil))
                  ((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (setq msg (apply #'format fmt args)))))
          (should (bufferp (maduin-cockpit-show)))
          (should (get-buffer "*maduin-cockpit*"))
          (should (string-match-p "chaplet" msg)))
      (when (get-buffer "*maduin-cockpit*")
        (kill-buffer "*maduin-cockpit*")))))

(ert-deftest maduin-test-cockpit-inbox-embed-absent-noop ()
  :tags '(maduin)
  ;; chaplet not loadable → nil + message, never an error.
  (let ((msg nil))
    (cl-letf (((symbol-function 'require)
               (lambda (_feature &optional _na _ne) nil))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq msg (apply #'format fmt args)))))
      (should-not (maduin-cockpit--embed-inbox)))
    (should (string-match-p "chaplet" msg))))

(ert-deftest maduin-test-cockpit-inbox-embed-present ()
  :tags '(maduin)
  ;; chaplet available (mocked) → lower window returned, view set inbox,
  ;; cockpit buffer stays in the main (selected) window.
  (let ((view nil)
        (buf (get-buffer-create "*maduin-cockpit*")))
    (unwind-protect
        (progn
          (switch-to-buffer buf)
          (let ((main (selected-window)))
            (cl-letf (((symbol-function 'require)
                       (lambda (_feature &optional _na _ne) t))
                      ((symbol-function 'chaplet-list-set-view)
                       (lambda (name) (setq view name))))
              (let ((win (maduin-cockpit--embed-inbox)))
                (unwind-protect
                    (progn
                      (should (windowp win))
                      (should (eq view 'inbox))
                      (should (eq (selected-window) main))
                      (should (eq (window-buffer main) buf))
                      (should-not (eq win main)))
                  (when (and win (windowp win) (window-live-p win))
                    (ignore-errors (delete-window win))))))))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-inbox-refresh-noop-no-buffer ()
  :tags '(maduin)
  ;; Inbox buffer absent → refresh fn never invoked, silent no-op.
  (when (get-buffer "*chaplet*") (kill-buffer "*chaplet*"))
  (let ((called nil))
    (cl-letf (((symbol-function 'chaplet-list-refresh)
               (lambda () (setq called t))))
      (should-not (maduin-cockpit--inbox-refresh))
      (should-not called))))

(ert-deftest maduin-test-cockpit-inbox-refresh-refreshes-when-present ()
  :tags '(maduin)
  ;; Inbox buffer live in chaplet-list-mode → refresh invoked once.
  (let ((buf (get-buffer-create "*chaplet*"))
        (called nil))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq major-mode 'chaplet-list-mode))
          (cl-letf (((symbol-function 'chaplet-list-refresh)
                     (lambda () (setq called t))))
            (should (maduin-cockpit--inbox-refresh))
            (should called)))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-auto-refresh-inbox-absent-no-error ()
  :tags '(maduin)
  ;; Visible cockpit + inbox absent → auto-refresh refreshes cockpit and the
  ;; inbox refresh is a silent no-op (no error).
  (let ((buf (get-buffer-create "*maduin-cockpit*"))
        (count 0))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window) (lambda (_b _f) t))
                  ((symbol-function 'maduin-cockpit-refresh)
                   (lambda () (setq count (1+ count)))))
          (with-current-buffer buf (tabulated-list-mode))
          (maduin-cockpit--auto-refresh)
          (should (= count 1)))
      (when maduin-cockpit--timer
        (cancel-timer maduin-cockpit--timer)
        (setq maduin-cockpit--timer nil))
      (kill-buffer buf))))

;;; 8f. cockpit-evil (evil-aware keybindings + inbox jump)

(ert-deftest maduin-test-cockpit-evil-symbols-exist ()
  :tags '(maduin)
  (should (fboundp 'maduin-cockpit--bind))
  (should (fboundp 'maduin-cockpit--evil-setup))
  (should (commandp 'maduin-cockpit-inbox)))

(ert-deftest maduin-test-cockpit-evil-plain-map-bindings ()
  :tags '(maduin)
  ;; Plain map carries r/q/i via the single-source-of-truth helper.
  (should (eq (lookup-key maduin-cockpit-map (kbd "r"))
              'maduin-cockpit-refresh))
  (should (eq (lookup-key maduin-cockpit-map (kbd "q"))
              'quit-window))
  (should (eq (lookup-key maduin-cockpit-map (kbd "i"))
              'maduin-cockpit-inbox))
  ;; Attach/kill removed: RET and k are unbound in the plain map.
  (should-not (lookup-key maduin-cockpit-map (kbd "RET")))
  (should-not (lookup-key maduin-cockpit-map (kbd "k")))
  ;; Leak suppression is evil-only: plain map must NOT bind "v".
  (should-not (lookup-key maduin-cockpit-map (kbd "v"))))

(ert-deftest maduin-test-cockpit-evil-setup-mirrors-normal-motion ()
  :tags '(maduin)
  ;; featurep+mock recorder: normal/motion receive the shared bindings AND
  ;; the leak keys (v etc.) bound to nil.
  (let ((recorded nil))
    (cl-letf (((symbol-function 'featurep)
               (lambda (f &optional _sub) (eq f 'evil)))
              ((symbol-function 'fboundp)
               (lambda (f) (eq f 'evil-define-key*)))
              ((symbol-function 'evil-define-key*)
               (lambda (state _map key def)
                 (push (list state key def) recorded))))
      (maduin-cockpit--evil-setup)
      (dolist (binding maduin-cockpit--bindings)
        (let ((key (kbd (car binding))) (def (cdr binding)))
          (should (member (list 'normal key def) recorded))
          (should (member (list 'motion key def) recorded))))
      ;; v (and every suppress key) → nil in BOTH evil states.
      (should (member (list 'normal (kbd "v") nil) recorded))
      (should (member (list 'motion (kbd "v") nil) recorded))
      (dolist (key maduin-cockpit--evil-suppress-keys)
        (should (member (list 'normal (kbd key) nil) recorded))
        (should (member (list 'motion (kbd key) nil) recorded))))))

(ert-deftest maduin-test-cockpit-evil-setup-no-evil-noop ()
  :tags '(maduin)
  ;; evil absent → guard short-circuits, evil-define-key* never called.
  (let ((calls 0))
    (cl-letf (((symbol-function 'featurep) (lambda (_f &optional _s) nil))
              ((symbol-function 'evil-define-key*)
               (lambda (&rest _) (cl-incf calls))))
      (maduin-cockpit--evil-setup)
      (should (= calls 0)))))

(ert-deftest maduin-test-cockpit-inbox-selects-window ()
  :tags '(maduin)
  ;; Inbox window live → select-window invoked on it.
  (let ((win (selected-window))
        (selected nil))
    (cl-letf (((symbol-function 'get-buffer-window)
               (lambda (_buf &optional _f) win))
              ((symbol-function 'select-window)
               (lambda (w) (setq selected w))))
      (maduin-cockpit-inbox)
      (should (eq selected win)))))

(ert-deftest maduin-test-cockpit-inbox-absent-message ()
  :tags '(maduin)
  ;; Inbox absent → polite message, no error, no selection.
  (let ((msg nil))
    (cl-letf (((symbol-function 'get-buffer-window)
               (lambda (_buf &optional _f) nil))
              ((symbol-function 'select-window)
               (lambda (_w) (error "must not select")))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq msg (apply #'format fmt args)))))
      (maduin-cockpit-inbox)
      (should (string-match-p "no inbox" msg)))))

;;; 9. main

(ert-deftest maduin-test-main-commands-exist ()
  :tags '(maduin)
  (dolist (f '(maduin-mode
               maduin-start
               maduin-stop
               maduin-status
               maduin-restart
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

(ert-deftest maduin-test-workspace-cleanup-removes-real-worktree ()
  :tags '(maduin)
  ;; Scratch repo: git init + seed commit off the harness dir, then a REAL
  ;; worktree + branch, all under a temp dir.  Seams point cleanup at the
  ;; scratch repo; after cleanup the worktree is unregistered and the branch
  ;; is gone.  Never touches the real main repo.
  (let* ((dir (maduin-test--temp-dir))
         (wt (expand-file-name "wt" dir))
         (branch "cleanup-branch-xyz")
         (result nil)
         (maduin-workspace--main-root-fn (lambda () dir)))
    (unwind-protect
        (progn
          (maduin-workspace--git dir "init" "-q")
          (maduin-workspace--git dir "config" "user.email" "t@example.com")
          (maduin-workspace--git dir "config" "user.name" "Test")
          (write-region "seed\n" nil (expand-file-name "seed.txt" dir))
          (maduin-workspace--git dir "add" "-A")
          (maduin-workspace--git dir "commit" "-q" "-m" "seed")
          (maduin-workspace--git dir "worktree" "add" wt "-b" branch)
          (should (maduin-bd-worktree-real-p wt))
          (cl-letf (((symbol-function 'maduin-workspace-path) (lambda (_s) wt))
                    ((symbol-function 'maduin-workspace-branch) (lambda (_s) branch)))
            (setq result (maduin-workspace-cleanup "test-seat")))
          (should (eq result t))
          (should-not (maduin-bd-worktree-real-p wt))
          (should (/= 0 (car (maduin-workspace--git-output
                              dir "rev-parse" "--verify" branch)))))
      (ignore-errors (delete-directory wt t))
      (ignore-errors (maduin-workspace--git dir "worktree" "prune"))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest maduin-test-workspace-cleanup-missing-worktree ()
  :tags '(maduin)
  ;; Worktree dir missing → t immediately, no git calls at all.
  (let* ((dir (maduin-test--temp-dir))
         (maduin-workspace--main-root-fn (lambda () dir))
         (maduin-workspace--git-fn (lambda (&rest _) (error "git-fn must not run")))
         (maduin-workspace--git-output-fn
          (lambda (&rest _) (error "git-output-fn must not run"))))
    (unwind-protect
        (cl-letf (((symbol-function 'maduin-workspace-path)
                   (lambda (_s) (expand-file-name "no-such-wt" dir)))
                  ((symbol-function 'maduin-workspace-branch)
                   (lambda (_s) "missing-branch-xyz")))
          (should (eq (maduin-workspace-cleanup "test-seat") t)))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest maduin-test-workspace-cleanup-remove-failure ()
  :tags '(maduin)
  ;; Branch verifies, but `git worktree remove' fails → nil + warning,
  ;; tree left (no delete-directory fallback).
  (let* ((dir (maduin-test--temp-dir))
         (wt (expand-file-name "wt" dir))
         (logged nil)
         (maduin-workspace--main-root-fn (lambda () dir))
         (maduin-workspace--git-fn
          (lambda (_d &rest args) (if (member "remove" args) 1 0)))
         (maduin-workspace--git-output-fn
          (lambda (_d &rest _args) (cons 0 "abc123\n"))))
    (unwind-protect
        (cl-letf (((symbol-function 'maduin-workspace-path) (lambda (_s) wt))
                  ((symbol-function 'maduin-workspace-branch)
                   (lambda (_s) "cleanup-branch-xyz"))
                  ((symbol-function 'maduin-workspace--log-warning)
                   (lambda (msg) (setq logged msg))))
          (make-directory wt t)
          (should (null (maduin-workspace-cleanup "test-seat")))
          (should (stringp logged))
          (should (file-directory-p wt)))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest maduin-test-workspace-cleanup-missing-branch ()
  :tags '(maduin)
  ;; Worktree exists but branch no longer verifies → t without branch -D.
  ;; git-fn errors on any "-D" call; reaching it would flip the result to nil.
  (let* ((dir (maduin-test--temp-dir))
         (wt (expand-file-name "wt" dir))
         (maduin-workspace--main-root-fn (lambda () dir))
         (maduin-workspace--git-fn
          (lambda (_d &rest args)
            (when (member "-D" args) (error "branch -D must not run"))
            0))
         (maduin-workspace--git-output-fn
          (lambda (_d &rest _args) (cons 128 "fatal: needed a single revision\n"))))
    (unwind-protect
        (cl-letf (((symbol-function 'maduin-workspace-path) (lambda (_s) wt))
                  ((symbol-function 'maduin-workspace-branch)
                   (lambda (_s) "ghost-branch-xyz")))
          (make-directory wt t)
          (should (eq (maduin-workspace-cleanup "test-seat") t)))
      (ignore-errors (delete-directory dir t)))))

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

(ert-deftest maduin-test-land-branch-success ()
  :tags '(maduin)
  ;; Commit → verify branch → rebase onto main → fast-forward main.  Rebase
  ;; of a branch already containing main is a no-op that still exits 0, so
  ;; this subsumes the old `merge-base --is-ancestor' shortcut.
  (let* ((calls nil)
         (maduin-pipeline--worktree-path-fn (lambda (_s) maduin-test--dir))
         (maduin-pipeline--branch-fn (lambda (_s) "seat-branch-xyz"))
         (maduin-pipeline--main-root-fn (lambda () maduin-test--dir))
         (maduin-pipeline--git-fn
          (lambda (_dir &rest args) (push args calls) 0))
         (maduin-pipeline--git-output-fn
          (lambda (_dir &rest args)
            (push args calls)
           (cond
            ((member "commit" args) (cons 0 ""))
            ((member "rev-parse" args) (cons 0 "abc123\n"))
            ((member "rebase" args) (cons 0 ""))
            ((member "merge" args) (cons 0 ""))))))
    (should (eq (maduin-pipeline-land-branch "test-seat") t))
    ;; Both the rebase and the ff-only merge must run, with exact args.
    (should (cl-some (lambda (a)
                       (equal a '("rebase" "main" "seat-branch-xyz")))
                     calls))
    (should (cl-some (lambda (a)
                       (equal a '("merge" "--ff-only" "seat-branch-xyz")))
                     calls))))

(ert-deftest maduin-test-land-branch-nothing-to-commit-still-merges ()
  :tags '(maduin)
  ;; Worker pre-committed → `git commit' reports "nothing to commit" (exit
  ;; 1), but the branch still gets rebased onto main and fast-forwarded,
  ;; returning t on success.
  (let ((maduin-pipeline--worktree-path-fn (lambda (_s) maduin-test--dir))
        (maduin-pipeline--branch-fn (lambda (_s) "seat-branch-xyz"))
        (maduin-pipeline--main-root-fn (lambda () maduin-test--dir))
        (maduin-pipeline--git-fn (lambda (_dir &rest _args) 0))
        (maduin-pipeline--git-output-fn
         (lambda (_dir &rest args)
           (cond
            ((member "commit" args)
             (cons 1 "nothing to commit, working tree clean\n"))
            ((member "rev-parse" args) (cons 0 "abc123\n"))
            ((member "rebase" args) (cons 0 ""))
            ((member "merge" args) (cons 0 ""))))))
    (should (eq (maduin-pipeline-land-branch "test-seat") t))))

(ert-deftest maduin-test-land-branch-rebase-conflict ()
  :tags '(maduin)
  ;; Commit succeeds (or nothing to commit) → branch verifies → rebase
  ;; reports a conflict → abort the failed rebase in main (leaving the
  ;; branch at its pre-rebase state, no jammed rebase) → returns `conflict'.
  (let* ((calls nil)
         (maduin-pipeline--worktree-path-fn (lambda (_s) maduin-test--dir))
         (maduin-pipeline--branch-fn (lambda (_s) "seat-branch-xyz"))
         (maduin-pipeline--main-root-fn (lambda () maduin-test--dir))
         (maduin-pipeline--git-fn
          (lambda (_dir &rest args) (push args calls) 0))
         (maduin-pipeline--git-output-fn
          (lambda (_dir &rest args)
            (cond
             ((member "commit" args) (cons 0 ""))
             ((member "rev-parse" args) (cons 0 "abc123\n"))
             ((member "rebase" args)
              (cons 1 "CONFLICT (content): Merge conflict in foo.el\n"))))))
    (should (eq (maduin-pipeline-land-branch "test-seat") 'conflict))
    ;; The failed rebase must be aborted so the branch isn't left mid-rebase.
    (should (cl-some (lambda (args) (equal args '("rebase" "--abort"))) calls))))

(ert-deftest maduin-test-land-branch-rebase-failure ()
  :tags '(maduin)
  ;; Rebase fails for a non-conflict reason (e.g. a git error) → log a
  ;; warning naming the branch → return nil.
  (let ((logged nil)
        (maduin-pipeline--worktree-path-fn (lambda (_s) maduin-test--dir))
        (maduin-pipeline--branch-fn (lambda (_s) "seat-branch-xyz"))
        (maduin-pipeline--main-root-fn (lambda () maduin-test--dir))
        (maduin-pipeline--git-fn (lambda (_dir &rest _args) 0))
        (maduin-pipeline--git-output-fn
         (lambda (_dir &rest args)
           (cond
            ((member "commit" args) (cons 0 ""))
            ((member "rev-parse" args) (cons 0 "abc123\n"))
            ((member "rebase" args)
             (cons 128 "fatal: update_ref failed\n"))))))
    (cl-letf (((symbol-function 'maduin-workspace--log-warning)
               (lambda (msg) (setq logged msg))))
      (should (null (maduin-pipeline-land-branch "test-seat")))
      (should (stringp logged))
      (should (string-match-p "rebase" logged)))))

(ert-deftest maduin-test-land-branch-ff-only-fail ()
  :tags '(maduin)
  ;; Rebase ok, but the fast-forward merge fails (e.g. main moved
  ;; concurrently) → log a warning naming the branch → return nil.
  (let ((logged nil)
        (maduin-pipeline--worktree-path-fn (lambda (_s) maduin-test--dir))
        (maduin-pipeline--branch-fn (lambda (_s) "seat-branch-xyz"))
        (maduin-pipeline--main-root-fn (lambda () maduin-test--dir))
        (maduin-pipeline--git-fn (lambda (_dir &rest _args) 0))
        (maduin-pipeline--git-output-fn
         (lambda (_dir &rest args)
           (cond
            ((member "commit" args) (cons 0 ""))
            ((member "rev-parse" args) (cons 0 "abc123\n"))
            ((member "rebase" args) (cons 0 ""))
            ((member "merge" args)
             (cons 1 "fatal: Not possible to fast-forward, aborting.\n"))))))
    (cl-letf (((symbol-function 'maduin-workspace--log-warning)
               (lambda (msg) (setq logged msg))))
      (should (null (maduin-pipeline-land-branch "test-seat")))
      (should (stringp logged))
      (should (string-match-p "ff-only" logged)))))

(ert-deftest maduin-test-land-branch-missing-branch ()
  :tags '(maduin)
  ;; Commit done (or nothing to commit), but the seat branch does not exist
  ;; → logs a warning naming the branch and returns nil (never rebases).
  (let ((logged nil)
        (maduin-pipeline--worktree-path-fn (lambda (_s) maduin-test--dir))
        (maduin-pipeline--branch-fn (lambda (_s) "seat-branch-xyz"))
        (maduin-pipeline--main-root-fn (lambda () maduin-test--dir))
        (maduin-pipeline--git-fn (lambda (_dir &rest _args) 0))
        (maduin-pipeline--git-output-fn
         (lambda (_dir &rest args)
           (cond
            ((member "commit" args) (cons 0 ""))
            ((member "rev-parse" args)
             (cons 128 "fatal: needed a single revision\n"))))))
    (cl-letf (((symbol-function 'maduin-workspace--log-warning)
               (lambda (msg) (setq logged msg))))
      (should (null (maduin-pipeline-land-branch "test-seat")))
      (should (stringp logged))
      (should (string-match-p "seat-branch-xyz" logged)))))

(ert-deftest maduin-test-config-workspaces-land-on-stop ()
  :tags '(maduin)
  (let ((ws (cdr (assq 'workspaces maduin-config))))
    (should (eq (alist-get 'land-on-stop ws) t))))

;;; 11. repairer config

(ert-deftest maduin-test-config-repairer-keys ()
  :tags '(maduin)
  (let ((repairer (cdr (assq 'repairer maduin-config))))
    (should (eq (alist-get 'enabled repairer) t))
    (should (string= (alist-get 'model repairer) "opencode-go/deepseek-v4-pro"))
    (should (= (alist-get 'max-retries repairer) 3))))

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

;;; 13. bd scratch helpers

(defun maduin-test--bd-delete (id)
  "Force-delete scratch bead ID. Never errors."
  (condition-case nil
      (call-process shell-file-name nil nil nil shell-command-switch
                    (format "bd delete %s --force" id))
    (error nil)))

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
         (maduin-dispatch--landed-fn (lambda (_seat) t))
         (maduin-dispatch--close-fn (lambda (task out &optional _dir) (setq closed (cons task out)) t))
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
         (released nil)
         (closed nil)
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn (lambda (_w _m _a _p) "s-1"))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--release-fn (lambda (task) (setq released task) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--comment-fn (lambda (task text) (setq commented (cons task text)) t))
          (maduin-dispatch--close-fn (lambda (task _out &optional _dir) (setq closed task) t))
         (maduin-dispatch--session-delete-fn (lambda (_sid) t)))
    (unwind-protect
        (progn
          (maduin-dispatch-implement "t1")
          (maduin-dispatch--on-complete "s-1" 'failed)
          (should (equal (car commented) "t1"))
          ;; Failed session must release the claim (status → open).
          (should (equal released "t1"))
          (should-not closed)
          (should-not maduin-dispatch--active))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-land-not-in-main-releases ()
  :tags '(maduin)
  ;; Land reports success but the landed-fn gate says the branch never
  ;; reached main (maduin-zxe incident) → comment + release, never close.
  (let* ((dir (maduin-test--temp-dir))
         (commented nil)
         (released nil)
         (closed nil)
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn (lambda (_w _m _a _p) "s-landed"))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--diff-fn
          (lambda (_sid) (list '((file . "a.el") (patch . "+x")))))
         (maduin-dispatch--land-fn (lambda (_seat) t))
         (maduin-dispatch--landed-fn (lambda (_seat) nil))
         (maduin-dispatch--close-fn (lambda (task _out &optional _dir) (setq closed task) t))
         (maduin-dispatch--comment-fn (lambda (task text) (setq commented (cons task text)) t))
         (maduin-dispatch--release-fn (lambda (task) (setq released task) t))
         (maduin-dispatch--session-delete-fn (lambda (_sid) t)))
    (unwind-protect
        (progn
          (maduin-dispatch-implement "t1")
          (maduin-dispatch--on-complete "s-landed" 'completed)
          (should-not closed)
          (should (equal (car commented) "t1"))
          (should (string-match-p "not in main" (cdr commented)))
          (should (equal released "t1"))
          (should-not maduin-dispatch--active))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-usage-limit-falls-back ()
  :tags '(maduin)
  ;; A usage-limited implementer session re-dispatches on the fallback
  ;; (go flash) model, holding the claim; a second failure releases it.
  (let* ((dir (maduin-test--temp-dir))
         (run-count 0)
         (last-model nil)
         (commented nil)
         (released nil)
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn
          (lambda (_w m _a _p)
            (setq run-count (1+ run-count))
            (setq last-model m)
            (format "s-%d" run-count)))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--release-fn (lambda (task) (setq released task) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--comment-fn (lambda (task text) (setq commented (cons task text)) t))
         (maduin-dispatch--session-delete-fn (lambda (_sid) t)))
    (unwind-protect
        (cl-letf (((symbol-function 'maduin-session-usage-limited-p)
                   (lambda (_sid) t)))
          (maduin-dispatch-implement "t1")
          (should (string= last-model "opencode/deepseek-v4-flash-free"))
          ;; Usage limit → fallback re-dispatch (go flash), claim held.
          (maduin-dispatch--on-complete "s-1" 'failed)
          (should (= run-count 2))
          (should (string= last-model "opencode-go/deepseek-v4-flash"))
          (should (equal commented
                         '("t1" . "usage limit — retrying with fallback model")))
          (should-not released)
          (should (= (length maduin-dispatch--active) 1))
          ;; Fallback already attempted → second failure releases.
          (maduin-dispatch--on-complete "s-2" 'failed)
          (should (= run-count 2))
          (should (equal released "t1"))
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
         (maduin-dispatch--close-fn (lambda (_t _o &optional _dir) t))
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

(ert-deftest maduin-test-dispatch-completion-land-fail-releases ()
  :tags '(maduin)
  ;; Non-conflict land failure (nil) must release the claim so the task
  ;; returns to open instead of staying in_progress forever.
  (let* ((dir (maduin-test--temp-dir))
         (released nil)
         (closed nil)
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn (lambda (_w _m _a _p) "s-1"))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--release-fn (lambda (task) (setq released task) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--diff-fn (lambda (_sid) nil))
         (maduin-dispatch--land-fn (lambda (_seat) nil))
         (maduin-dispatch--comment-fn (lambda (_task _text) t))
         (maduin-dispatch--close-fn (lambda (task _o &optional _dir) (setq closed task) t))
         (maduin-dispatch--session-delete-fn (lambda (_sid) t)))
    (unwind-protect
        (progn
          (maduin-dispatch-implement "t1")
          (maduin-dispatch--on-complete "s-1" 'completed)
          (should (equal released "t1"))
          (should-not closed))
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
         (maduin-dispatch--in-progress-fn (lambda () nil))
         (maduin-dispatch--open-epics-fn (lambda () nil)))
    (unwind-protect
        (progn
          (maduin-dispatch-run-loop)
          (should (= run-count 2))
          (should (= (length maduin-dispatch--active) 2)))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-orphaned-tasks ()
  :tags '(maduin)
  ;; in_progress tasks with a live dispatch session are NOT orphans.
  (let ((maduin-dispatch--in-progress-fn (lambda () '("o1" "o2" "live")))
        (maduin-dispatch--active
         (list (list :handle "s-1" :seat "ifrit" :role 'implementer :task "live"))))
    (should (equal (maduin-dispatch--orphaned-tasks) '("o1" "o2")))))

(ert-deftest maduin-test-dispatch-recover-redispatches-orphans ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (run-count 0)
         (maduin-dispatch--active nil)
         (maduin-dispatch--in-progress-fn (lambda () '("orphan-1")))
         (maduin-dispatch--session-run-fn
          (lambda (_w _m _a _p)
            (setq run-count (1+ run-count))
            (format "s-%d" run-count)))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir)))
    (unwind-protect
        (progn
          (should (= (maduin-dispatch--recover) 1))
          (should (= run-count 1))
          (should (cl-find-if (lambda (e) (string= (plist-get e :task) "orphan-1"))
                              maduin-dispatch--active)))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-start-stop-timer ()
  :tags '(maduin)
  (let ((maduin-dispatch--timer nil)
        (maduin-dispatch--active nil)
        (maduin-dispatch--in-progress-fn (lambda () nil))
        (maduin-dispatch--session-delete-fn (lambda (_sid) t)))
    (unwind-protect
        (progn
          (maduin-dispatch-start)
          (should maduin-dispatch--timer)
          (maduin-dispatch-stop)
          (should-not maduin-dispatch--timer))
      (maduin-dispatch-stop))))

(ert-deftest maduin-test-dispatch-soft-stop-drains ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (deleted '())
         (maduin-dispatch--active nil)
         (maduin-dispatch--draining nil)
         (maduin-dispatch--timer nil)
         (maduin-dispatch--session-run-fn (lambda (_w _m _a _p) "s-1"))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--diff-fn (lambda (_sid) nil))
         (maduin-dispatch--land-fn (lambda (_seat) t))
         (maduin-dispatch--close-fn (lambda (_t _o &optional _dir) t))
         (maduin-dispatch--session-delete-fn (lambda (sid) (push sid deleted) t)))
    (unwind-protect
        (progn
          (maduin-dispatch-implement "t1")
          (should (= (length maduin-dispatch--active) 1))
          ;; Soft stop: draining set, in-flight session NOT deleted.
          (maduin-dispatch-stop)
          (should maduin-dispatch--draining)
          (should (= (length maduin-dispatch--active) 1))
          (should-not deleted)
          ;; Run-loop is a no-op while draining (no new picks).
          (let ((maduin-dispatch--ready-fn (lambda () '("t2"))))
            (maduin-dispatch-run-loop)
            (should (= (length maduin-dispatch--active) 1)))
          ;; Last session completes → drained + deleted.
          (maduin-dispatch--on-complete "s-1" 'completed)
          (should-not maduin-dispatch--draining)
          (should-not maduin-dispatch--active)
          (should (member "s-1" deleted)))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-hard-stop-deletes ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (deleted '())
         (maduin-dispatch--active nil)
         (maduin-dispatch--draining nil)
         (maduin-dispatch--timer nil)
         (maduin-dispatch--session-run-fn (lambda (_w _m _a _p) "s-1"))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--session-delete-fn (lambda (sid) (push sid deleted) t)))
    (unwind-protect
        (progn
          (maduin-dispatch-implement "t1")
          (should (= (length maduin-dispatch--active) 1))
          (maduin-dispatch-stop t)          ; hard
          (should-not maduin-dispatch--active)
          (should (member "s-1" deleted))
          (should-not maduin-dispatch--draining))
      (delete-directory dir t))))

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
         (maduin-dispatch--in-progress-fn (lambda () nil))
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
         (maduin-dispatch--close-fn (lambda (task _out &optional _dir) (setq closed task) t))
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
    (should (string-match-p "--acceptance" tmpl))
    (should (string-match-p "--deps" tmpl))
    (should (string-match-p "implementation instructions" (downcase tmpl)))
    (should (string-match-p "files" (downcase tmpl)))
    (should (string-match-p "interfaces" (downcase tmpl)))
    (should (string-match-p "bd show" tmpl))
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
                  ("C-c s p" . maduin-designer-pending-tasks)))
    (should (eq (lookup-key maduin-mode-map (kbd (car pair))) (cdr pair)))))

(ert-deftest maduin-test-main-start-zero-sessions ()
  :tags '(maduin)
  (let ((maduin-dispatch--timer nil)
        (maduin-dispatch--active nil)
        (maduin-dispatch--in-progress-fn (lambda () nil))
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
          (maduin-stop t)                  ; hard stop tears down live sessions
          (should-not maduin-dispatch--timer)
          (should-not maduin-dispatch--active)
          (should (member "s-stop-1" deleted)))
      (maduin-dispatch-stop t))))

;;; 19. full-loop integration (mock opencode, chained seams)

(ert-deftest maduin-test-full-loop-epic-to-close ()
  :tags '(maduin)
  (let* ((epic "ert-epic-fake")
         (task "ert-epic-fake.1"))
    (cl-letf (((symbol-function 'maduin-bd-create-epic)
               (lambda (_title _desc) "ert-epic-fake"))
              ((symbol-function 'maduin-bd-create-task)
               (lambda (_title _desc _parent) "ert-epic-fake.1"))
              ((symbol-function 'maduin-bd-defer)
               (lambda (_id) t))
              ((symbol-function 'maduin-bd-update-design-acceptance)
               (lambda (_id _design _acceptance) t))
              ((symbol-function 'maduin-bd-undefer)
               (lambda (_id) t))
              ((symbol-function 'maduin-bd-ready-tasks)
               (lambda () (list "ert-epic-fake.1"))))
      (ignore epic)
      ;; 1. a deferred task is filed for the designer (Ramuh).
      (should (maduin-bd-defer task))
      ;; 2. designer fills design + stages (defer + staged label).
      (should (maduin-bd-update-design-acceptance task "design body" "acceptance body"))
      ;; 3. approved work consumes via bd ready: undefer → ready.
      (should (maduin-bd-undefer task))
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
             (maduin-dispatch--in-progress-fn (lambda () nil))
             (maduin-dispatch--open-epics-fn (lambda () nil))
             (maduin-dispatch--session-run-fn (lambda (_w _m _a _p) "s-loop-1"))
             (maduin-dispatch--claim-fn (lambda (_t) t))
             (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
             (maduin-dispatch--workdir-fn (lambda (_s) dir))
             (maduin-dispatch--diff-fn
              (lambda (_sid) (list '((file . "x.el") (patch . "+1")))))
             (maduin-dispatch--land-fn (lambda (seat) (setq landed seat) t))
             (maduin-dispatch--landed-fn (lambda (_seat) t))
             (maduin-dispatch--close-fn (lambda (t2 _out &optional _dir) (setq closed t2) t))
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
          (delete-directory dir t))))))

;;; 20. v0.3 — batched review gate (Odin)

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

(ert-deftest maduin-test-review-epic-children-closed-p ()
  :tags '(maduin)
  (let ((maduin-review--epic-children-fn (lambda (_epic) '("t1" "t2")))
        (maduin-review--show-fn (lambda (_id) (list :status "closed"))))
    (should (maduin-review--epic-children-closed-p "epic-x")))
  (let ((maduin-review--epic-children-fn (lambda (_epic) '("t1" "t2")))
        (maduin-review--show-fn
         (lambda (id)
           (list :status (if (string= id "t2") "in_progress" "closed")))))
    (should-not (maduin-review--epic-children-closed-p "epic-x")))
  ;; no children → not complete.
  (let ((maduin-review--epic-children-fn (lambda (_epic) nil))
        (maduin-review--show-fn (lambda (_id) (list :status "closed"))))
    (should-not (maduin-review--epic-children-closed-p "epic-x"))))

(ert-deftest maduin-test-review-note-epic-land-records-once ()
  :tags '(maduin)
  (let ((maduin-review--epic-starts nil)
        (maduin-review--main-root-fn (lambda () "/repo"))
        (maduin-review--git-output-fn
         (lambda (_dir &rest _args) (cons 0 "sha-pre-first\n"))))
    (should (maduin-review--note-epic-land "epic-x"))
    (should (equal (cdr (assoc "epic-x" maduin-review--epic-starts))
                   "sha-pre-first"))
    ;; later lands keep the original start.
    (should-not (maduin-review--note-epic-land "epic-x"))))

(ert-deftest maduin-test-review-epic-diff ()
  :tags '(maduin)
  (let ((maduin-review--epic-starts '(("epic-x" . "abc")))
        (maduin-review--main-root-fn (lambda () "/repo"))
        (maduin-review--git-output-fn
         (lambda (_dir &rest args)
           (cons 0 (mapconcat #'identity args " ")))))
    (should (string-match-p "abc\\.\\.HEAD" (maduin-review--epic-diff "epic-x"))))
  ;; missing start → fall back to last-land parent HEAD~1.
  (let ((maduin-review--epic-starts nil)
        (maduin-review--main-root-fn (lambda () "/repo"))
        (maduin-review--git-output-fn
         (lambda (_dir &rest args)
           (cons 0 (mapconcat #'identity args " ")))))
    (should (string-match-p "HEAD~1\\.\\.HEAD" (maduin-review--epic-diff "epic-x")))))

(ert-deftest maduin-test-review-blocked-p ()
  :tags '(maduin)
  (let ((maduin-review--query-fn (lambda (_q) '("drift-task-1"))))
    (should (maduin-review--blocked-p)))
  (let ((maduin-review--query-fn (lambda (_q) nil)))
    (should-not (maduin-review--blocked-p))))

(ert-deftest maduin-test-review-gate-approved-closes-epic ()
  :tags '(maduin)
  (let* ((maduin-review--epic-starts '(("epic-x" . "abc")))
         (cmds nil)
         (maduin-review--main-root-fn (lambda () "/repo"))
         (maduin-review--git-output-fn
          (lambda (_dir &rest args)
            (if (member "diff" args)
                (cons 0 "+fake diff\n")
              (cons 0 "abc\n"))))
         (maduin-review--query-fn (lambda (_q) nil))
         (maduin-review--session-run-fn (lambda (_w _m _a _p) "sid-1"))
         (maduin-review--complete-p-fn (lambda (_sid) 'completed))
         (maduin-review--session-output-fn (lambda (_sid) "REVIEW: APPROVED\n"))
         (maduin-review--run-fn (lambda (cmd) (push cmd cmds) (cons 0 "")))
         (maduin-review--comment-fn (lambda (_id _text) t)))
    (should (eq (maduin-review-gate "epic-x") 'approved))
    ;; goal met → epic closed.
    (should (cl-find-if (lambda (c) (string-match-p "bd close epic-x" c)) cmds))
    ;; approved → recorded start dropped.
    (should-not (assoc "epic-x" maduin-review--epic-starts))))

(ert-deftest maduin-test-review-gate-drift-creates-drift-fix ()
  :tags '(maduin)
  (let* ((maduin-review--epic-starts '(("epic-x" . "abc")))
         (cmds nil)
         (maduin-review--main-root-fn (lambda () "/repo"))
         (maduin-review--git-output-fn
          (lambda (_dir &rest _args) (cons 0 "diff")))
         (maduin-review--query-fn (lambda (_q) nil))
         (maduin-review--session-run-fn (lambda (_w _m _a _p) "sid-1"))
         (maduin-review--complete-p-fn (lambda (_sid) 'completed))
         (maduin-review--session-output-fn
          (lambda (_sid) "REVIEW: DRIFT fix the widget\n"))
         (maduin-review--run-fn (lambda (cmd) (push cmd cmds) (cons 0 "drift-task-1\n")))
         (maduin-review--comment-fn (lambda (_id _text) t)))
    (should (eq (maduin-review-gate "epic-x") 'drift))
    (should (cl-find-if (lambda (c) (string-match-p "drift-fix" c)) cmds))
    (should (cl-find-if (lambda (c) (string-match-p "widget" c)) cmds))
    ;; drift → epic stays open: no close, recorded start preserved.
    (should-not (cl-find-if (lambda (c) (string-match-p "bd close epic-x" c)) cmds))
    (should (equal (cdr (assoc "epic-x" maduin-review--epic-starts)) "abc"))))

(ert-deftest maduin-test-review-gate-disabled ()
  :tags '(maduin)
  (let ((maduin-config '((reviewer (enabled . nil)))))
    (should (null (maduin-review-gate "epic-x")))))

(ert-deftest maduin-test-review-maybe-review-epic-when-complete ()
  :tags '(maduin)
  (let* ((gate-called nil)
         (maduin-review--epic-starts nil)
         (maduin-review--show-fn
          (lambda (_id) (list :parent "epic-x" :status "closed")))
         (maduin-review--epic-children-fn (lambda (_epic) '("t1")))
         (maduin-review--main-root-fn (lambda () "/repo"))
         (maduin-review--git-output-fn
          (lambda (_dir &rest _args) (cons 0 "sha\n"))))
    (cl-letf (((symbol-function 'maduin-review-gate)
               (lambda (epic) (setq gate-called epic) 'approved)))
      (should (eq (maduin-review--maybe-review-epic "t1") 'approved))
      (should (string= gate-called "epic-x"))
      ;; start recorded before the gate ran.
      (should (equal (cdr (assoc "epic-x" maduin-review--epic-starts)) "sha")))))

(ert-deftest maduin-test-review-maybe-review-epic-not-complete ()
  :tags '(maduin)
  (let* ((gate-called nil)
         (maduin-review--show-fn
          (lambda (id)
            (if (string= id "t1")
                (list :parent "epic-x" :status "in_progress")
              (list :status "in_progress"))))
          (maduin-review--epic-children-fn (lambda (_epic) '("t1" "t2"))))
    (cl-letf (((symbol-function 'maduin-review-gate)
               (lambda (_epic) (setq gate-called t) 'approved)))
      (should (null (maduin-review--maybe-review-epic "t1")))
      (should-not gate-called))))

(ert-deftest maduin-test-review-maybe-review-epic-no-parent ()
  :tags '(maduin)
  (let* ((gate-called nil)
         (maduin-review--show-fn (lambda (_id) (list :status "closed" :parent nil))))
    (cl-letf (((symbol-function 'maduin-review-gate)
               (lambda (_epic) (setq gate-called t) 'approved)))
      (should (null (maduin-review--maybe-review-epic "orphan")))
      (should-not gate-called))))

(provide 'maduin-test)

;;; maduin-test.el ends here
