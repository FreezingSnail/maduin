;;; super-harness-resolver.el --- dedicated merge-conflict resolver session  -*- lexical-binding: t; -*-

;;; Commentary:

;; "Beadle" — one-shot, dedicated opencode session per seat for
;; resolving land-into-main merge conflicts.  Not a fleet poller.

;;; Code:

(require 'cl-lib)

(defconst super-harness-resolver--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing super-harness-resolver.el.")

;;; Ensure sibling harness modules resolve when loaded directly.
(add-to-list 'load-path super-harness-resolver--dir)

(require 'super-harness-session)
(require 'super-harness-workspace)
(require 'super-harness-config)

(defvar super-harness-resolver-processes nil
  "Alist of (SEAT-NAME . PROCESS) for active resolver sessions.")

(defun super-harness-resolver--config-get (key &optional default)
  "Return resolver section KEY from super-harness-config, or DEFAULT.
Honor explicit nil values; fall back only when KEY is absent."
  (let* ((section (when (boundp 'super-harness-config)
                    (cdr (assq 'resolver super-harness-config))))
         (cell (and section (assq key section))))
    (if cell (cdr cell) default)))

(defun super-harness-resolver--prompt (seat-name)
  "Return Beadle priming prompt for SEAT-NAME."
  (format
   "You are Beadle, the merge-conflict resolver for seat %s. You are in worktree %s on branch %s. A land into main failed with conflicts. Task: 1) git merge main (fetch first if needed) 2) resolve ALL conflicts 3) git add -A 4) git commit -m 'resolve merge conflicts (%s)' 5) output exactly RESOLVED_DONE on success. Do not touch other files. Report blockers instead of guessing."
   seat-name
   (super-harness-workspace-path seat-name)
   seat-name
   seat-name))

(defun super-harness-resolver--prime (seat-name proc buf)
  "Send Beadle prompt for SEAT-NAME via process-send-string when PROC
is alive; otherwise insert into BUF (degraded, opencode missing)."
  (let ((text (super-harness-resolver--prompt seat-name)))
    (if (and proc (process-live-p proc))
        (process-send-string proc text)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert text)))))))

(defun super-harness-resolver-active-p (seat-name)
  "Return t when resolver process for SEAT-NAME is alive."
  (let ((proc (cdr (assoc seat-name super-harness-resolver-processes))))
    (and proc (process-live-p proc))))

(defun super-harness-resolver-start (seat-name)
  "Start dedicated resolver session for SEAT-NAME.

Return existing live process when one is already active.  Spawn a new
session via `super-harness-session-create' with role `resolver' and
model from config `resolver.model' (default \"deepseek-v3\").  Return
nil when config `resolver.enabled' is nil, or when no process could be
spawned (opencode missing — buffer still created, degraded)."
  (let ((existing (cdr (assoc seat-name super-harness-resolver-processes))))
    (cond
     ((not (super-harness-resolver--config-get 'enabled t))
      (message "super-harness: resolver disabled for seat %s" seat-name)
      nil)
     ((and existing (process-live-p existing))
      existing)
     (t
      (let* ((workdir (super-harness-workspace-path seat-name))
             (model (super-harness-resolver--config-get 'model "deepseek-v3"))
             (default-directory (or workdir default-directory))
             (buf (super-harness-session-create
                   seat-name 'resolver model workdir))
             (proc (and buf (get-buffer-process buf))))
        (when buf
          (super-harness-resolver--prime seat-name proc buf)
          (setq super-harness-resolver-processes
                (cons (cons seat-name proc)
                      (assq-delete-all seat-name
                                       super-harness-resolver-processes))))
        proc)))))

(defun super-harness-resolver-stop (seat-name)
  "Stop resolver session for SEAT-NAME.  Kill process and buffer.
Return non-nil when anything was killed."
  (setq super-harness-resolver-processes
        (assq-delete-all seat-name super-harness-resolver-processes))
  (super-harness-session-kill seat-name))

(provide 'super-harness-resolver)

;;; super-harness-resolver.el ends here
