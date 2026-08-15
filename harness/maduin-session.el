;;; maduin-session.el --- autonomous one-shot sessions + legacy seat buffers  -*- lexical-binding: t; -*-

;;; Commentary:

;; Two substrates share this file.
;;
;; 1. AUTONOMOUS (one-shot) substrate — the current interface:
;;    `maduin-session-run' spawns `opencode run --format json --auto'
;;    in a worktree, parses the NDJSON event stream for a structured
;;    completion signal (`step_finish.reason` + `tool_use.state.status`),
;;    and exposes diff/delete via `opencode export` / `opencode session
;;    delete`.  The process exit code is deliberately NOT trusted —
;;    permission denials can exit 0 — completion is parsed from events.
;;
;; 2. LEGACY seat-buffer substrate (compat shims) — kept so pipeline /
;;    agent / resolver / cockpit keep working until the dispatch
;;    machinery (bd .5) rebuilds orchestration on top of the new
;;    interface.  Each seat lives in one buffer backed by a long-lived
;;    opencode TUI subprocess driven by `process-send-string'.

;;; Code:

(require 'cl-lib)
(require 'json)

(require 'maduin-config nil t)

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

(defun maduin-session-run (workdir model agent plan)
  "Run one autonomous task in WORKDIR with MODEL, AGENT and PLAN via
`opencode run'.  Spawns `opencode run --dir WORKDIR -m MODEL --agent
AGENT --format json --auto --title <handle> PLAN' asynchronously (the
`--agent AGENT' pair is omitted when AGENT is nil or empty); a
process-filter consumes the NDJSON event stream and a sentinel fires
`maduin-session-on-complete-hook'.

Return a session handle (string) for `maduin-session-complete-p',
`maduin-session-diff' and `maduin-session-delete', or nil when the
opencode CLI is unavailable or the process cannot be spawned."
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
                        :command (append (list exe "run" "--dir" workdir "-m" model)
                                         (when (and agent (not (string-empty-p agent)))
                                           (list "--agent" agent))
                                         (list "--format" "json" "--auto"
                                               "--title" handle plan))
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
          (setq-local maduin-session--done-p nil))
        (puthash handle buf maduin-session--registry)
        handle))))

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

;;; ====================================================================
;;; Legacy seat-buffer substrate (compat shims — superseded by .5)
;;; ====================================================================

(defvar maduin-session-on-exit-hook nil
  "Hooks run when an agent process exits.")

;; Buffer-local seat state.
(defvar maduin-seat nil)
(defvar maduin-role nil)
(defvar maduin-model nil)
(defvar maduin-agent nil)
(defvar maduin-status nil)
(defvar maduin-started-at nil)
(defvar maduin-current-task nil)
(defvar maduin-intent nil
  "Intended opencode command (list) when no process could be spawned.")
(defvar maduin-workdir nil)

(defun maduin-session--buffer-name (role seat)
  "Buffer name for ROLE seat SEAT."
  (format "*maduin/%s-%s*" role seat))

(defun maduin-session--buffer (seat-name)
  "Find agent buffer whose `maduin-seat' is SEAT-NAME."
  (cl-find-if
   (lambda (buf)
     (and (buffer-live-p buf)
          (local-variable-p 'maduin-seat buf)
          (string= (buffer-local-value 'maduin-seat buf) seat-name)))
   (buffer-list)))

(defun maduin-session--sentinel (proc event)
  "Sentinel for agent process PROC.  EVENT is the exit string."
  (let ((buf (process-buffer proc)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq maduin-status 'dead)
        (setq maduin-current-task nil)
        (message "maduin: session %s exited (%s)"
                 maduin-seat event))
      (run-hooks 'maduin-session-on-exit-hook))))

(defun maduin-session-create (seat-name role model &optional workdir agent)
  "Create session buffer for SEAT-NAME with ROLE, MODEL and AGENT in WORKDIR.
WORKDIR defaults to the project root (via `maduin-project-root',
falling back to `default-directory') when omitted.  AGENT is the opencode
agent name passed via `--agent' after `--model'; it is omitted from the
spawned command and intent when nil or empty.

Return the buffer.  Launches opencode as subprocess when the CLI is
available; otherwise still returns a buffer holding the spawn intent
in `maduin-intent' with status `dead'."
  (let* ((buf (get-buffer-create (maduin-session--buffer-name role seat-name)))
         (workdir (or workdir
                      (if (fboundp 'maduin-project-root)
                          (maduin-project-root)
                        default-directory)))
         (exe (executable-find maduin-opencode-command)))
    (with-current-buffer buf
      (when (fboundp 'compilation-mode)
        (compilation-mode))
      (setq-local maduin-seat seat-name)
      (setq-local maduin-role role)
      (setq-local maduin-model model)
      (setq-local maduin-agent agent)
      (setq-local maduin-status 'running)
      (setq-local maduin-started-at (float-time))
      (setq-local maduin-current-task nil)
      (setq-local maduin-workdir workdir)
      (setq-local maduin-intent
                  (append (list maduin-opencode-command "--model" model)
                          (when (and agent (not (string-empty-p agent)))
                            (list "--agent" agent))))
      (if exe
          (progn
            (make-process
             :name (format "maduin-%s-%s" role seat-name)
             :buffer buf
             :command (append (list exe "--model" model)
                              (when (and agent (not (string-empty-p agent)))
                                (list "--agent" agent)))
             :sentinel #'maduin-session--sentinel)
            (set-process-query-on-exit-flag (get-buffer-process buf) nil))
        (setq maduin-status 'dead)
        (message "maduin: opencode not found; session %s created without process"
                 seat-name)))
    buf))

(defun maduin-session-kill (seat-name)
  "Kill process and buffer for SEAT-NAME.  Return non-nil if anything was killed."
  (let* ((buf (maduin-session--buffer seat-name))
         (proc (and buf (get-buffer-process buf)))
         (had (or (and proc (process-live-p proc))
                  (and buf (buffer-live-p buf)))))
    (when (and proc (process-live-p proc))
      (ignore-errors (kill-process proc)))
    (when (and buf (buffer-live-p buf))
      (ignore-errors (kill-buffer buf)))
    (and had t)))

(defun maduin-session-list ()
  "Return alist ((SEAT-NAME . STATUS) ...) of all agent sessions."
  (cl-loop for buf in (buffer-list)
           when (and (buffer-live-p buf)
                     (local-variable-p 'maduin-seat buf))
           collect (cons (buffer-local-value 'maduin-seat buf)
                         (buffer-local-value 'maduin-status buf))))

(defun maduin-session-switch (seat-name)
  "Switch to buffer of SEAT-NAME.  Signal error if missing."
  (let ((buf (maduin-session--buffer seat-name)))
    (unless buf
      (error "maduin: no session for seat %s" seat-name))
    (switch-to-buffer buf)))

(defun maduin-session-alive-p (seat-name)
  "Return t when SEAT-NAME has a live process and status not `dead'."
  (let* ((buf (maduin-session--buffer seat-name))
         (proc (and buf (get-buffer-process buf)))
         (status (and buf (buffer-local-value 'maduin-status buf))))
    (and proc (process-live-p proc) (not (eq status 'dead)))))

(provide 'maduin-session)

;;; maduin-session.el ends here
