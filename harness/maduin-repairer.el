;;; maduin-repairer.el --- repairer session (merge conflicts + drift)  -*- lexical-binding: t; -*-

;;; Commentary:

;; "Phoenix" — one-shot, dedicated opencode session per seat for
;; repair work: resolving land-into-main merge conflicts and fixing
;; post-review drift.  Not a fleet poller.  The `slugineer-repairer'
;; agent supplies the role discipline; the prime text is only a
;; short task instruction.

;;; Code:

(require 'cl-lib)

(defconst maduin-repairer--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing maduin-repairer.el.")

;;; Ensure sibling harness modules resolve when loaded directly.
(add-to-list 'load-path maduin-repairer--dir)

(require 'maduin-session)
(require 'maduin-workspace)
(require 'maduin-config)
(require 'maduin-bd-bridge)

(declare-function maduin-pipeline-land-branch "maduin-pipeline")

(defvar maduin-repairer-processes nil
  "Alist of (SEAT-NAME . PROCESS) for active repairer sessions.")

(defvar maduin-repairer-pending-tasks nil
  "Alist of (SEAT-NAME . TASK-ID) awaiting repairer completion.
Set by `maduin-repairer-register' when the pipeline dispatches
a repairer for a conflicting land on TASK-ID.")

(defvar maduin-repairer-retries nil
  "Alist of (SEAT-NAME . RETRY-COUNT) of repairer respawns per seat.")

(defvar maduin-repairer-modes nil
  "Alist of (SEAT-NAME . MODE) of the active repair mode per seat.
MODE is `merge-conflict' (default) or `drift-fix'; preserved across
retries in `maduin-repairer--on-exit'.")

(defun maduin-repairer--config-get (key &optional default)
  "Return repairer section KEY from maduin-config, or DEFAULT.
Honor explicit nil values; fall back only when KEY is absent."
  (let* ((section (when (boundp 'maduin-config)
                    (cdr (assq 'repairer maduin-config))))
         (cell (and section (assq key section))))
    (if cell (cdr cell) default)))

(defun maduin-repairer--prompt (seat-name mode)
  "Return short repairer task instruction for SEAT-NAME in MODE.
MODE is `merge-conflict' (default) or `drift-fix'.  The
`slugineer-repairer' agent supplies the role discipline; this text
is only the task, and always requires outputting RESOLVED_DONE."
  (pcase mode
    ('drift-fix
     (format
      "Repair seat %s in worktree %s: fix the drift flagged by review, commit the fix, and output exactly RESOLVED_DONE on success. Report blockers instead of guessing."
      seat-name (maduin-workspace-path seat-name)))
    (_
     (format
      "Repair seat %s in worktree %s: a land into main failed with merge conflicts. Resolve all conflicts, commit the merge, and output exactly RESOLVED_DONE on success. Report blockers instead of guessing."
      seat-name (maduin-workspace-path seat-name)))))

(defun maduin-repairer--prime (seat-name proc buf mode)
  "Send repairer instruction for SEAT-NAME (MODE) via process-send-string
when PROC is alive; otherwise insert into BUF (degraded, opencode missing)."
  (let ((text (maduin-repairer--prompt seat-name mode)))
    (if (and proc (process-live-p proc))
        (process-send-string proc text)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert text)))))))

(defun maduin-repairer-active-p (seat-name)
  "Return t when repairer process for SEAT-NAME is alive."
  (let ((proc (cdr (assoc seat-name maduin-repairer-processes))))
    (and proc (process-live-p proc))))

(defun maduin-repairer-register (seat-name task-id)
  "Record TASK-ID as pending for SEAT-NAME and reset retry count to 1."
  (setq maduin-repairer-pending-tasks
        (cons (cons seat-name task-id)
              (assoc-delete-all seat-name maduin-repairer-pending-tasks)))
  (setq maduin-repairer-retries
        (cons (cons seat-name 1)
              (assoc-delete-all seat-name maduin-repairer-retries)))
  nil)

(defun maduin-repairer--scan-done (buf)
  "Return t when BUF holds the RESOLVED_DONE marker."
  (and (buffer-live-p buf)
       (with-current-buffer buf
         (string-match-p "RESOLVED_DONE" (buffer-string)))))

(defun maduin-repairer--on-exit (proc seat-name)
  "Handle repairer PROC exit for SEAT-NAME.
When the repairer buffer holds RESOLVED_DONE, re-land; on t close the
pending task, on 'conflict retry up to repairer.max-retries, on nil
leave the task open.  When the marker is absent, log and leave open."
  (let ((buf (process-buffer proc)))
    (if (maduin-repairer--scan-done buf)
        (let ((land (maduin-pipeline-land-branch seat-name)))
          (cond
           ((eq land t)
            (let ((task (cdr (assoc seat-name maduin-repairer-pending-tasks))))
              (when task
                (maduin-bd-close task nil)
                (setq maduin-repairer-pending-tasks
                      (assoc-delete-all seat-name maduin-repairer-pending-tasks)))
              (setq maduin-repairer-retries
                    (assoc-delete-all seat-name maduin-repairer-retries))
              (maduin-repairer-stop seat-name)))
           ((eq land 'conflict)
            (let* ((max (or (maduin-repairer--config-get 'max-retries 3) 3))
                   (n (1+ (or (cdr (assoc seat-name maduin-repairer-retries)) 0)))
                   (mode (cdr (assoc seat-name maduin-repairer-modes))))
              (if (< n max)
                  (progn
                    (setq maduin-repairer-retries
                          (cons (cons seat-name n)
                                (assoc-delete-all seat-name maduin-repairer-retries)))
                    (maduin-repairer-start seat-name mode))
                (maduin-workspace--log-warning
                 (format "repairer: seat %s retries exhausted (%d); task left open"
                         seat-name max))
                (setq maduin-repairer-retries
                      (assoc-delete-all seat-name maduin-repairer-retries)))))
           (t
            (maduin-workspace--log-warning
             (format "repairer: re-land failed for seat %s; task left open" seat-name))
            (setq maduin-repairer-retries
                  (assoc-delete-all seat-name maduin-repairer-retries)))))
      (maduin-workspace--log-warning
       (format "repairer: seat %s exited without RESOLVED_DONE; task left open"
               seat-name))
      (setq maduin-repairer-retries
            (assoc-delete-all seat-name maduin-repairer-retries)))))

(defun maduin-repairer-attach-sentinel (proc seat-name)
  "Attach completion sentinel to repairer PROC for SEAT-NAME.
No-op when PROC is not live or Emacs is batch/non-interactive.
On process exit delegates to `maduin-repairer--on-exit'."
  (when (and proc (process-live-p proc))
    (set-process-sentinel
     proc
     (lambda (p _event)
       (unless (bound-and-true-p noninteractive)
         (when (eq (process-status p) 'exit)
           (maduin-repairer--on-exit p seat-name)))))))

(defun maduin-repairer-start (seat-name &optional mode)
  "Start dedicated repairer session for SEAT-NAME in MODE.

MODE is `merge-conflict' (default) or `drift-fix'; it adjusts the
short task instruction sent after spawn.  Return existing live
process when one is already active.  Spawn a new session via
`maduin-session-create' with role `repairer', model from config
`repairer.model' (default opencode-go/deepseek-v4-pro) and agent
from config `repairer.agent' (default \"slugineer-repairer\").
Return nil when config `repairer.enabled' is nil, or when no process
could be spawned (opencode missing — buffer still created, degraded)."
  (let* ((mode (or mode 'merge-conflict))
         (existing (cdr (assoc seat-name maduin-repairer-processes))))
    (cond
     ((not (maduin-repairer--config-get 'enabled t))
      (message "maduin: repairer disabled for seat %s" seat-name)
      nil)
     ((and existing (process-live-p existing))
      existing)
     (t
      (let* ((workdir (maduin-workspace-path seat-name))
             (model (maduin-repairer--config-get 'model "opencode-go/deepseek-v4-pro"))
             (agent (maduin-repairer--config-get 'agent "slugineer-repairer"))
             (default-directory (or workdir default-directory))
             (buf (maduin-session-create
                   seat-name 'repairer model workdir agent))
             (proc (and buf (get-buffer-process buf))))
        (when buf
          (maduin-repairer--prime seat-name proc buf mode)
          (maduin-repairer-attach-sentinel proc seat-name)
          (setq maduin-repairer-processes
                (cons (cons seat-name proc)
                      (assq-delete-all seat-name
                                       maduin-repairer-processes)))
          (setq maduin-repairer-modes
                (cons (cons seat-name mode)
                      (assoc-delete-all seat-name maduin-repairer-modes))))
        proc)))))

(defun maduin-repairer-stop (seat-name)
  "Stop repairer session for SEAT-NAME.  Kill process and buffer.
Return non-nil when anything was killed."
  (setq maduin-repairer-processes
        (assq-delete-all seat-name maduin-repairer-processes))
  (setq maduin-repairer-modes
        (assoc-delete-all seat-name maduin-repairer-modes))
  (maduin-session-kill seat-name))

(provide 'maduin-repairer)

;;; maduin-repairer.el ends here
