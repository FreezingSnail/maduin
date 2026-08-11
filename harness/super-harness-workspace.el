;;; super-harness-workspace.el --- per-seat worktree provisioning  -*- lexical-binding: t; -*-

;;; Commentary:

;; Provision and locate per-seat git worktrees.  Worktrees are named
;; after seats; each lives under config `workspaces.path'.

;;; Code:

(require 'cl-lib)
(require 'super-harness-bd-bridge)
(require 'super-harness-config)

(defun super-harness-workspace--root ()
  "Return absolute workspaces root from config, default `harness/workspaces'."
  (let* ((workspaces (cdr (assq 'workspaces super-harness-config)))
         (path (or (cdr (assq 'path workspaces)) "harness/workspaces")))
    (expand-file-name path)))

(defun super-harness-workspace--log-warning (msg)
  "Log MSG as warning via super-harness-log if available, else `message'."
  (if (fboundp 'super-harness-log)
      (super-harness-log 'warn msg)
    (message "[super-harness-workspace] WARN: %s" msg)))

(defun super-harness-workspace-path (seat-name)
  "Return worktree path for SEAT-NAME under workspaces root. No creation."
  (expand-file-name seat-name (super-harness-workspace--root)))

(defun super-harness-workspace-branch (seat-name)
  "Return branch name for SEAT-NAME (default: seat name)."
  seat-name)

(defun super-harness-workspace-exists-p (seat-name)
  "Return non-nil if a worktree for SEAT-NAME exists (per bd worktree list)."
  (not (null (cdr (assoc seat-name (super-harness-bd-worktree-list))))))

(defun super-harness-workspace-ensure (seat-name)
  "Return worktree path for SEAT-NAME, creating it if missing.
Reuse existing worktree when present.  Return nil if creation fails."
  (let ((existing (cdr (assoc seat-name (super-harness-bd-worktree-list)))))
    (if existing
        existing
      (make-directory (super-harness-workspace--root) t)
      ;; bd worktree create accepts a path; pass full path under
      ;; workspaces root so `workspace-path' and actual location agree.
      (let ((target (super-harness-workspace-path seat-name)))
        (if (file-exists-p target)
            target
          (or (super-harness-bd-worktree-create target)
              (progn
                (super-harness-workspace--log-warning
                 (format "worktree create failed for seat %s" seat-name))
                nil)))))))

(provide 'super-harness-workspace)

;;; super-harness-workspace.el ends here
