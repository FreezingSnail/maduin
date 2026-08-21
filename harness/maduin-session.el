;;; maduin-session.el --- autonomous one-shot sessions  -*- lexical-binding: t; -*-

;;; Commentary:

;; AUTONOMOUS (one-shot) substrate — the current interface:
;; `maduin-session-run' spawns `opencode run --format json --auto'
;; in a worktree, parses the NDJSON event stream for a structured
;; completion signal (`step_finish.reason` + `tool_use.state.status`),
;; and exposes diff/delete via `opencode export` / `opencode session
;; delete`.  The process exit code is deliberately NOT trusted —
;; permission denials can exit 0 — completion is parsed from events.

;;; Code:

(require 'cl-lib)
(require 'json)

(require 'maduin-config nil t)
(require 'maduin-backend)

(condition-case nil
    (require 'maduin-logging)
  (error nil))

(defvar maduin-opencode-command "opencode"
  "Executable name of the opencode CLI.")

(defun maduin-session--log (fmt &rest args)
  "Log a maduin session message via `maduin-log' or `message'."
  (let ((msg (apply #'format fmt args)))
    (if (fboundp 'maduin-log)
        (maduin-log 'info msg)
      (message "maduin-session: %s" msg))))

;;; ====================================================================
;;; Autonomous (one-shot) substrate: opencode run + NDJSON parsing
;;; ====================================================================

(defvar maduin-session--registry (make-hash-table :test #'equal)
  "Hash table mapping session handle (string) to its hidden buffer.
The buffer holds the subprocess plus buffer-local state:
`maduin-session--handle', `maduin-session--session-id',
`maduin-session--status', `maduin-session--pending', `maduin-session--done-p'.")

(defvar maduin-session--seq 0
  "Monotonic counter for generating unique session handles.")

(defvar maduin-session-on-complete-hook nil
  "Hooks run when an autonomous task session reaches a terminal state.
Each hook receives two args: (SID STATUS) where STATUS is `completed'
or `failed'.  Run from the process sentinel once per session.")

(defvar maduin-session-on-event-hook nil
  "Hooks notified with live autonomous-session events when available.")

;; Buffer-local state for run-session buffers (set via `setq-local').
(defvar maduin-session--handle nil
  "Session handle (the value returned by `maduin-session-run').")
(defvar maduin-session--session-id nil
  "Real opencode session id (ses_...) captured from NDJSON, or nil.")
(defvar maduin-session--status 'running
  "Session status: `running', `completed' or `failed'.")
(defvar maduin-session--pending ""
  "Accumulator for partially received NDJSON lines.")
(defvar maduin-session--done-p nil
  "Non-nil once the completion hook has fired for this session.")

(defvar maduin-session--usage-limited nil
  "Non-nil when the run hit a provider usage/rate limit.")

(defconst maduin-session--usage-limit-re
  (regexp-opt '("usage limit" "rate limit" "rate-limit" "too many requests"
                "429" "quota" "insufficient")
              t)
  "Regexp matching provider usage/rate-limit error text.")

(defun maduin-session--usage-limit-line-p (line)
  "Non-nil when NDJSON LINE reports a provider usage/rate limit.
Only error-carrying events (an `error' field or a session.error type)
are considered, so model text mentioning quota/429 in ordinary output
does not set the flag."
  (and (stringp line)
       (string-match-p "\\\(\"error\"\\|session\\.error\\\)" line)
       (string-match-p maduin-session--usage-limit-re line)))

(defun maduin-session--parse-line (line)
  "Parse one NDJSON LINE emitted by `opencode run --format json'.
Return a plist (:type TYPE :session-id SID :terminal TERMINAL) where
TERMINAL is `completed' (step_finish reason stop), `failed'
(step_finish reason error, or tool_use state.status error), or nil.
Return nil when LINE is not valid JSON or lacks a `type'."
  (condition-case nil
      (let* ((obj (json-read-from-string line))
             (type (cdr (assq 'type obj)))
             (sid (cdr (assq 'sessionID obj)))
             (part (cdr (assq 'part obj)))
             (terminal
              (pcase type
                ("step_finish"
                 (pcase (cdr (assq 'reason part))
                   ("error" 'failed)
                   ("stop" 'completed)
                   (_ nil)))
                ("tool_use"
                 (let ((state (cdr (assq 'state part))))
                   (if (and state
                            (string= (cdr (assq 'status state)) "error"))
                       'failed
                     nil)))
                (_ nil))))
        (list :type type :session-id sid :terminal terminal))
    (error nil)))

(defun maduin-session--consume-line (line)
  "Parse one NDJSON LINE and update buffer-local session state."
  (when (maduin-session--usage-limit-line-p line)
    (setq maduin-session--usage-limited t))
  (let ((evt (maduin-session--parse-line line)))
    (when evt
      (let ((sid (plist-get evt :session-id))
            (term (plist-get evt :terminal)))
        (when (and sid (not maduin-session--session-id))
          (setq maduin-session--session-id sid))
        (pcase term
          ('failed (setq maduin-session--status 'failed))
          ('completed
           (unless (eq maduin-session--status 'failed)
             (setq maduin-session--status 'completed))))))))

(defun maduin-session--drain ()
  "Consume complete NDJSON lines from `maduin-session--pending'."
  (let ((idx (string-match "\n" maduin-session--pending)))
    (while idx
      (let ((line (substring maduin-session--pending 0 idx)))
        (setq maduin-session--pending
              (substring maduin-session--pending (1+ idx)))
        (unless (string-empty-p line)
          (maduin-session--consume-line line)))
      (setq idx (string-match "\n" maduin-session--pending)))))

(defun maduin-session--run-filter (proc string)
  "Process-filter for run session PROC, consuming NDJSON in STRING."
  (let ((buf (process-buffer proc)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq maduin-session--pending
              (concat maduin-session--pending string))
        (maduin-session--drain)))))

(defun maduin-session--run-sentinel (proc _event)
  "Sentinel for run session PROC: finalize status and run the hook."
  (let ((buf (process-buffer proc)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        ;; Drain a trailing line that may lack a newline.
        (when (and (stringp maduin-session--pending)
                   (not (string-empty-p maduin-session--pending)))
          (maduin-session--consume-line maduin-session--pending)
          (setq maduin-session--pending ""))
        ;; Exit without a terminal event → incomplete → failed.
        (when (eq maduin-session--status 'running)
          (setq maduin-session--status 'failed))
        (unless maduin-session--done-p
          (setq maduin-session--done-p t)
          (run-hook-with-args 'maduin-session-on-complete-hook
                              maduin-session--handle
                              maduin-session--status))))))

(defun maduin-session--run-buffer (sid)
  "Return the hidden run-session buffer for SID (handle or real id).
Return nil when no live session matches."
  (let ((direct (gethash sid maduin-session--registry)))
    (cond
     ((and direct (buffer-live-p direct)) direct)
     (t
      (cl-find-if
       (lambda (b)
         (and (buffer-live-p b)
              (string= (buffer-local-value 'maduin-session--session-id b)
                       sid)))
       (hash-table-values maduin-session--registry))))))

(defun maduin-session--real-id (sid)
  "Return the real opencode session id for SID, or nil."
  (let ((buf (maduin-session--run-buffer sid)))
    (when buf
      (buffer-local-value 'maduin-session--session-id buf))))

(defun maduin-session--opencode-effort-valid-p (effort)
  "Return non-nil when EFFORT is a safe OpenCode variant argument."
  (and (stringp effort)
       (not (string-empty-p effort))
       (not (string-match-p "[[:space:]/]" effort))))

(defun maduin-session--opencode-run-command (executable workdir model agent handle plan
                                                         &optional effort)
  "Build autonomous opencode argv for WORKDIR, MODEL, AGENT, HANDLE and PLAN.
EXECUTABLE is the resolved opencode program.  Omit `--variant' for unusable
EFFORT and `--agent' for an empty AGENT, preserving the established autonomous
command line."
  (append (list executable "run" "--dir" workdir "-m" model)
          (when (maduin-session--opencode-effort-valid-p effort)
            (list "--variant" effort))
          (when (and agent (not (string-empty-p agent)))
            (list "--agent" agent))
          (list "--format" "json" "--auto" "--title" handle plan)))

(defun maduin-session--opencode-run (workdir model agent plan &optional effort)
  "Run autonomous OpenCode in WORKDIR with MODEL, AGENT, PLAN and EFFORT."
  (cl-block nil
    (let ((exe (executable-find maduin-opencode-command)))
      (unless exe
        (maduin-session--log "run: opencode not found")
        (cl-return nil))
      (let* ((handle (format "maduin-session-%d" (cl-incf maduin-session--seq)))
             (buf (generate-new-buffer (format " *%s*" handle)))
             (proc (condition-case nil
                       (make-process
                        :name (format "maduin-run-%d" maduin-session--seq)
                        :buffer buf
                        :command (maduin-session--opencode-run-command
                                  exe workdir model agent handle plan effort)
                        :filter #'maduin-session--run-filter
                        :sentinel #'maduin-session--run-sentinel
                        :noquery t)
                     (error nil))))
        (unless proc
          (kill-buffer buf)
          (maduin-session--log "run: failed to spawn opencode")
          (cl-return nil))
        (with-current-buffer buf
          (setq-local maduin-session--handle handle)
          (setq-local maduin-session--status 'running)
          (setq-local maduin-session--pending "")
          (setq-local maduin-session--session-id nil)
          (setq-local maduin-session--done-p nil)
          (setq-local maduin-session--usage-limited nil))
        (puthash handle buf maduin-session--registry)
        handle))))

(defun maduin-session-run (workdir model agent plan &optional effort)
  "Run one autonomous task in WORKDIR with MODEL, AGENT, PLAN and EFFORT.
Compatibility façade for the opencode adapter.  Return its opaque session
handle, or nil when opencode is unavailable or cannot be spawned."
  (maduin-session--opencode-run workdir model agent plan effort))

(defun maduin-session-complete-p (sid)
  "Return completion status of autonomous session SID.
One of `completed', `running' or `failed'.  An unknown SID is `failed';
a session whose process died without a terminal event is `failed'."
  (let ((buf (maduin-session--run-buffer sid)))
    (if (not buf)
        'failed
      (with-current-buffer buf
        (cond
         ((eq maduin-session--status 'completed) 'completed)
         ((eq maduin-session--status 'failed) 'failed)
          (t (let ((proc (get-buffer-process buf)))
               (if (and proc (process-live-p proc))
                   'running
                 'failed))))))))

(defun maduin-session-usage-limited-p (sid)
  "Return non-nil when run session SID hit a provider usage/rate limit."
  (let ((buf (maduin-session--run-buffer sid)))
    (and buf
         (buffer-live-p buf)
         (buffer-local-value 'maduin-session--usage-limited buf))))

(defun maduin-session--call (cmd)
  "Run CMD (list of strings) synchronously.  Return (STATUS . OUTPUT),
or nil when the call errors."
  (condition-case nil
      (let* ((buf (generate-new-buffer " *maduin-call*"))
             (status (apply #'call-process (car cmd) nil buf nil (cdr cmd))))
        (prog1 (cons status (with-current-buffer buf (buffer-string)))
          (kill-buffer buf)))
    (error nil)))

(defun maduin-session--extract-diffs (json-string)
  "Extract and flatten all diffs from `opencode export' JSON-STRING.
Return a list of diff alists (file, patch, additions, deletions,
status); nil on parse failure."
  (condition-case nil
      (let* ((obj (json-read-from-string json-string))
             (msgs (cdr (assq 'messages obj)))
             (msgs (if (vectorp msgs) (mapcar #'identity msgs) msgs))
             (diffs nil))
        (dolist (m msgs)
          (let* ((info (cdr (assq 'info m)))
                 (summary (and info (cdr (assq 'summary info))))
                 (ds (and summary (cdr (assq 'diffs summary)))))
            (when ds
              (dolist (d (if (vectorp ds) (mapcar #'identity ds) ds))
                (push d diffs)))))
        (nreverse diffs))
    (error nil)))

(defun maduin-session-diff (sid)
  "Return list of diffs for autonomous session SID via `opencode export'.
Each diff is an alist with keys file, patch, additions, deletions,
status (opencode export output).  Return nil on failure."
  (let ((real (maduin-session--real-id sid)))
    (when real
      (let ((res (maduin-session--call
                  (list maduin-opencode-command "export" real))))
        (and res
             (= 0 (car res))
             (maduin-session--extract-diffs (cdr res)))))))

(defun maduin-session-delete (sid)
  "Delete autonomous session SID via `opencode session delete'.
Kill the process and buffer, remove registry entries, and return t
when the opencode session was deleted, nil otherwise."
  (let ((buf (maduin-session--run-buffer sid)))
    (let ((real (and buf (buffer-local-value 'maduin-session--session-id buf))))
      (when buf
        (let ((proc (get-buffer-process buf)))
          (when (and proc (process-live-p proc))
            (delete-process proc))))
      (let ((keys nil))
        (maphash (lambda (k b) (when (eq b buf) (push k keys)))
                 maduin-session--registry)
        (dolist (k keys) (remhash k maduin-session--registry)))
      (when (and buf (buffer-live-p buf))
        (kill-buffer buf))
      (if real
          (let ((res (maduin-session--call
                      (list maduin-opencode-command "session" "delete" real))))
            (and res (= 0 (car res))))
        nil))))

(defun maduin-session--opencode-tui (root model _agent prompt &optional effort)
  "Return OpenCode TUI command for ROOT, MODEL, PROMPT and optional EFFORT.
AGENT is deliberately ignored: OpenCode's historical interactive command
never included it.  Unusable EFFORT is omitted like the autonomous adapter."
  (mapconcat #'identity
             (append
              (list (or (bound-and-true-p maduin-opencode-command) "opencode")
                    (shell-quote-argument root)
                    "-m" (shell-quote-argument model))
              (when (maduin-session--opencode-effort-valid-p effort)
                (list "--variant" (shell-quote-argument effort)))
              (list "--prompt" (shell-quote-argument prompt)))
             " "))

(maduin-backend-register
 'opencode
 (list :executable (or maduin-opencode-command "opencode")
       :run-fn #'maduin-session--opencode-run
       :tui-fn #'maduin-session--opencode-tui
       :complete-p-fn #'maduin-session-complete-p
       :diff-fn #'maduin-session-diff
       :delete-fn #'maduin-session-delete))

(provide 'maduin-session)

;;; maduin-session.el ends here
