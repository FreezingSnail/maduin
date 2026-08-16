;;; maduin-workspace.el --- per-seat worktree provisioning  -*- lexical-binding: t; -*-

;;; Commentary:

;; Provision and locate per-seat git worktrees.  Worktrees are named
;; after seats; each lives under config `workspaces.path'.

;;; Code:

(require 'cl-lib)
(require 'maduin-bd-bridge)
(require 'maduin-config)

(defun maduin-workspace--root ()
  "Return absolute workspaces root from config, default `harness/workspaces'.
Resolved under the current project root."
  (let* ((workspaces (cdr (assq 'workspaces maduin-config)))
         (path (or (cdr (assq 'path workspaces)) "harness/workspaces")))
    (expand-file-name path (maduin-project-root))))

(defun maduin-workspace--log-warning (msg)
  "Log MSG as warning via maduin-log if available, else `message'."
  (if (fboundp 'maduin-log)
      (maduin-log 'warn msg)
    (message "[maduin-workspace] WARN: %s" msg)))

(defun maduin-workspace-path (seat-name)
  "Return worktree path for SEAT-NAME under workspaces root. No creation."
  (expand-file-name seat-name (maduin-workspace--root)))

(defun maduin-workspace-branch (seat-name)
  "Return branch name for SEAT-NAME (default: seat name)."
  seat-name)

(defun maduin-workspace-exists-p (seat-name)
  "Return non-nil if a worktree for SEAT-NAME exists (per bd worktree list)."
  (not (null (cdr (assoc seat-name (maduin-bd-worktree-list))))))

(defun maduin-workspace--remove-stale (dir)
  "Remove stale worktree DIR when it is an empty (non-worktree) directory.
Return t when DIR is gone (removed or never existed), nil when DIR exists
but cannot be safely removed (non-empty)."
  (cond
   ((not (file-exists-p dir)) t)
   ((not (file-directory-p dir)) nil)
   ((directory-empty-p dir)
    (condition-case nil
        (progn (delete-directory dir) t)
      (error nil)))
   (t nil)))

(defun maduin-workspace--create (seat-name target)
  "Create a REAL git worktree for SEAT-NAME at TARGET.
Return worktree path on success, nil otherwise."
  (make-directory (maduin-workspace--root) t)
  (let ((created (maduin-bd-worktree-create
                  target (maduin-workspace-branch seat-name))))
    (if (and created (maduin-bd-worktree-real-p created))
        created
      (maduin-workspace--log-warning
       (format "worktree create failed for seat %s" seat-name))
      nil)))

(defun maduin-workspace-ensure (seat-name)
  "Return worktree path for SEAT-NAME, creating a REAL git worktree if missing.
Reuse an existing real worktree when present.  A stale directory (e.g. an
empty dir left by a prior bootstrap) is removed before creating the
worktree.  Return nil if creation fails."
  (let ((target (maduin-workspace-path seat-name)))
    (cond
     ;; Already a real, registered worktree → reuse.
     ((maduin-bd-worktree-real-p target) target)
     ;; Stale path (empty dir, not a worktree) → clear then create.
     ((file-exists-p target)
      (if (maduin-workspace--remove-stale target)
          (maduin-workspace--create seat-name target)
        (maduin-workspace--log-warning
         (format "worktree path %s exists but is not a worktree and not empty; refusing to replace"
                 target))
        nil))
     (t (maduin-workspace--create seat-name target)))))

(provide 'maduin-workspace)

;;; maduin-workspace.el ends here
