;;; maduin-resolver.el --- dedicated merge-conflict resolver session  -*- lexical-binding: t; -*-

;;; Commentary:

;; "Beadle" — one-shot, dedicated opencode session per seat for
;; resolving land-into-main merge conflicts.  Not a fleet poller.

;;; Code:

(require 'cl-lib)

(defconst maduin-resolver--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing maduin-resolver.el.")

;;; Ensure sibling harness modules resolve when loaded directly.
(add-to-list 'load-path maduin-resolver--dir)

(require 'maduin-session)
(require 'maduin-workspace)
(require 'maduin-config)
(require 'maduin-bd-bridge)

(declare-function maduin-pipeline-land-branch "maduin-pipeline")

(defvar maduin-resolver-processes nil
  "Alist of (SEAT-NAME . PROCESS) for active resolver sessions.")

(defvar maduin-resolver-pending-tasks nil
  "Alist of (SEAT-NAME . TASK-ID) awaiting resolver completion.
Set by `maduin-resolver-register' when the pipeline dispatches
a resolver for a conflicting land on TASK-ID.")

(defvar maduin-resolver-retries nil
  "Alist of (SEAT-NAME . RETRY-COUNT) of resolver respawns per seat.")

(defun maduin-resolver--config-get (key &optional default)
  "Return resolver section KEY from maduin-config, or DEFAULT.
Honor explicit nil values; fall back only when KEY is absent."
  (let* ((section (when (boundp 'maduin-config)
                    (cdr (assq 'resolver maduin-config))))
         (cell (and section (assq key section))))
    (if cell (cdr cell) default)))

(defun maduin-resolver--prompt (seat-name)
  "Return Beadle priming prompt for SEAT-NAME."
  (format
   "You are Beadle, the merge-conflict resolver for seat %s. You are in worktree %s on branch %s. A land into main failed with conflicts. Task: 1) git merge main (fetch first if needed) 2) resolve ALL conflicts 3) git add -A 4) git commit -m 'resolve merge conflicts (%s)' 5) output exactly RESOLVED_DONE on success. Do not touch other files. Report blockers instead of guessing."
   seat-name
   (maduin-workspace-path seat-name)
   seat-name
   seat-name))

(defun maduin-resolver--prime (seat-name proc buf)
  "Send Beadle prompt for SEAT-NAME via process-send-string when PROC
is alive; otherwise insert into BUF (degraded, opencode missing)."
  (let ((text (maduin-resolver--prompt seat-name)))
    (if (and proc (process-live-p proc))
        (process-send-string proc text)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert text)))))))

(defun maduin-resolver-active-p (seat-name)
  "Return t when resolver process for SEAT-NAME is alive."
  (let ((proc (cdr (assoc seat-name maduin-resolver-processes))))
    (and proc (process-live-p proc))))

(defun maduin-resolver-register (seat-name task-id)
  "Record TASK-ID as pending for SEAT-NAME and reset retry count to 1."
  (setq maduin-resolver-pending-tasks
        (cons (cons seat-name task-id)
              (assoc-delete-all seat-name maduin-resolver-pending-tasks)))
  (setq maduin-resolver-retries
        (cons (cons seat-name 1)
              (assoc-delete-all seat-name maduin-resolver-retries)))
  nil)

(defun maduin-resolver--scan-done (buf)
  "Return t when BUF holds the RESOLVED_DONE marker."
  (and (buffer-live-p buf)
       (with-current-buffer buf
         (string-match-p "RESOLVED_DONE" (buffer-string)))))

(defun maduin-resolver--on-exit (proc seat-name)
  "Handle resolver PROC exit for SEAT-NAME.
When the resolver buffer holds RESOLVED_DONE, re-land; on t close the
pending task, on 'conflict retry up to resolver.max-retries, on nil
leave the task open.  When the marker is absent, log and leave open."
  (let ((buf (process-buffer proc)))
    (if (maduin-resolver--scan-done buf)
        (let ((land (maduin-pipeline-land-branch seat-name)))
          (cond
           ((eq land t)
            (let ((task (cdr (assoc seat-name maduin-resolver-pending-tasks))))
              (when task
                (maduin-bd-close task nil)
                (setq maduin-resolver-pending-tasks
                      (assoc-delete-all seat-name maduin-resolver-pending-tasks)))
              (setq maduin-resolver-retries
                    (assoc-delete-all seat-name maduin-resolver-retries))
              (maduin-resolver-stop seat-name)))
           ((eq land 'conflict)
            (let* ((max (or (maduin-resolver--config-get 'max-retries 3) 3))
                   (n (1+ (or (cdr (assoc seat-name maduin-resolver-retries)) 0))))
              (if (< n max)
                  (progn
                    (setq maduin-resolver-retries
                          (cons (cons seat-name n)
                                (assoc-delete-all seat-name maduin-resolver-retries)))
                    (maduin-resolver-start seat-name))
                (maduin-workspace--log-warning
                 (format "resolver: seat %s retries exhausted (%d); task left open"
                         seat-name max))
                (setq maduin-resolver-retries
                      (assoc-delete-all seat-name maduin-resolver-retries)))))
           (t
            (maduin-workspace--log-warning
             (format "resolver: re-land failed for seat %s; task left open" seat-name))
            (setq maduin-resolver-retries
                  (assoc-delete-all seat-name maduin-resolver-retries)))))
      (maduin-workspace--log-warning
       (format "resolver: seat %s exited without RESOLVED_DONE; task left open"
               seat-name))
      (setq maduin-resolver-retries
            (assoc-delete-all seat-name maduin-resolver-retries)))))

(defun maduin-resolver-attach-sentinel (proc seat-name)
  "Attach completion sentinel to resolver PROC for SEAT-NAME.
No-op when PROC is not live or Emacs is batch/non-interactive.
On process exit delegates to `maduin-resolver--on-exit'."
  (when (and proc (process-live-p proc))
    (set-process-sentinel
     proc
     (lambda (p _event)
       (unless (bound-and-true-p noninteractive)
         (when (eq (process-status p) 'exit)
           (maduin-resolver--on-exit p seat-name)))))))

(defun maduin-resolver-start (seat-name)
  "Start dedicated resolver session for SEAT-NAME.

Return existing live process when one is already active.  Spawn a new
session via `maduin-session-create' with role `resolver' and
model from config `resolver.model' (default "opencode-go/deepseek-v4-pro").
Return nil when config `resolver.enabled' is nil, or when no process
could be spawned (opencode missing — buffer still created, degraded)."
  (let ((existing (cdr (assoc seat-name maduin-resolver-processes))))
    (cond
     ((not (maduin-resolver--config-get 'enabled t))
      (message "maduin: resolver disabled for seat %s" seat-name)
      nil)
     ((and existing (process-live-p existing))
      existing)
     (t
      (let* ((workdir (maduin-workspace-path seat-name))
             (model (maduin-resolver--config-get 'model "opencode-go/deepseek-v4-pro"))
             (default-directory (or workdir default-directory))
             (buf (maduin-session-create
                   seat-name 'resolver model workdir))
             (proc (and buf (get-buffer-process buf))))
        (when buf
          (maduin-resolver--prime seat-name proc buf)
          (maduin-resolver-attach-sentinel proc seat-name)
          (setq maduin-resolver-processes
                (cons (cons seat-name proc)
                      (assq-delete-all seat-name
                                       maduin-resolver-processes))))
        proc)))))

(defun maduin-resolver-stop (seat-name)
  "Stop resolver session for SEAT-NAME.  Kill process and buffer.
Return non-nil when anything was killed."
  (setq maduin-resolver-processes
        (assq-delete-all seat-name maduin-resolver-processes))
  (maduin-session-kill seat-name))

(provide 'maduin-resolver)

;;; maduin-resolver.el ends here
