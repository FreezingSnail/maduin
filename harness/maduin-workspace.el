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

(defun maduin-workspace-ensure (seat-name)
  "Return worktree path for SEAT-NAME, creating it if missing.
Reuse existing worktree when present.  Return nil if creation fails."
  (let ((existing (cdr (assoc seat-name (maduin-bd-worktree-list)))))
    (if existing
        existing
      (make-directory (maduin-workspace--root) t)
      ;; bd worktree create accepts a path; pass full path under
      ;; workspaces root so `workspace-path' and actual location agree.
      (let ((target (maduin-workspace-path seat-name)))
        (if (file-exists-p target)
            target
          (or (maduin-bd-worktree-create target)
              (progn
                (maduin-workspace--log-warning
                 (format "worktree create failed for seat %s" seat-name))
                nil)))))))

(provide 'maduin-workspace)

;;; maduin-workspace.el ends here
