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

(defun maduin-workspace--git (dir &rest args)
  "Run `git -C DIR ARGS...' via shell; return exit status.
Output is discarded.  Uses `call-process-shell-command' so the
exit status is available programmatically."
  (let ((default-directory dir)
        (cmd (format "git -C %s %s"
                     (shell-quote-argument dir)
                     (mapconcat #'shell-quote-argument args " "))))
    (call-process-shell-command cmd nil nil)))

(defun maduin-workspace--git-output (dir &rest args)
  "Run `git -C DIR ARGS...'; return (STATUS . OUTPUT)."
  (let* ((default-directory dir)
         (cmd (format "git -C %s %s"
                      (shell-quote-argument dir)
                      (mapconcat #'shell-quote-argument args " ")))
         (buf (get-buffer-create " *maduin-workspace-git*")))
    (with-current-buffer buf (erase-buffer))
    (cons (call-process-shell-command cmd nil buf)
          (with-current-buffer buf (buffer-string)))))

(defun maduin-workspace--main-root ()
  "Return main maduin repo root.
Prefer the directory containing maduin.el, else
`default-directory'."
  (or (and (locate-library "maduin")
           (file-name-directory (locate-library "maduin")))
      (expand-file-name default-directory)))

(defvar maduin-workspace--git-fn #'maduin-workspace--git
  "Function `(dir &rest args)' → exit status.  Injection seam for tests.")

(defvar maduin-workspace--git-output-fn #'maduin-workspace--git-output
  "Function `(dir &rest args)' → (STATUS . OUTPUT).  Injection seam for tests.")

(defvar maduin-workspace--main-root-fn #'maduin-workspace--main-root
  "Function `()' → main repo root.  Injection seam for tests.")

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

(defun maduin-workspace--dirty-p (worktree)
  "Return non-nil when WORKTREE has uncommitted changes.
A git failure reads as dirty: refusing to touch an unreadable tree is the
safe answer, since the alternative discards work."
  (let ((res (funcall maduin-workspace--git-output-fn
                      worktree "status" "--porcelain")))
    (or (/= 0 (car res))
        (not (string-empty-p (string-trim (or (cdr res) "")))))))

(defun maduin-workspace--ancestor-p (main ancestor descendant)
  "Return non-nil when ANCESTOR is an ancestor of DESCENDANT, asked from MAIN."
  (= 0 (funcall maduin-workspace--git-fn
                main "merge-base" "--is-ancestor" ancestor descendant)))

(defun maduin-workspace-sync (seat-name)
  "Bring SEAT-NAME's branch in line with main before new work is dispatched.

Seat worktrees are otherwise only reconciled with main at land time, which
means a seat implements against whatever main looked like when its branch was
last touched and only discovers the divergence once the work already exists.
Syncing first moves that discovery before the session is spawned.

Return:
  `synced'   → the branch now contains main (already current, reset, or rebased)
  `dirty'    → uncommitted changes; the tree is left untouched
  `conflict' → unlanded commits conflict with main; the rebase was aborted
  nil        → no worktree, or git failed

A branch already fully landed is reset to main; a branch holding unlanded
commits is rebased so that work survives.  Never signals."
  (condition-case err
      (let* ((wt (maduin-workspace-path seat-name))
             (branch (maduin-workspace-branch seat-name))
             (main (funcall maduin-workspace--main-root-fn)))
        (cond
         ((not (file-directory-p wt)) nil)
         ;; Branch already contains main → nothing to do.
         ((maduin-workspace--ancestor-p main "main" branch) 'synced)
         ((maduin-workspace--dirty-p wt)
          (maduin-workspace--log-warning
           (format "sync seat %s: uncommitted changes; left on a stale base"
                   seat-name))
          'dirty)
         ;; Nothing unlanded → discard the stale baseline outright.
         ((maduin-workspace--ancestor-p main branch "main")
          (if (= 0 (funcall maduin-workspace--git-fn wt "reset" "--hard" "main"))
              'synced
            (maduin-workspace--log-warning
             (format "sync seat %s: reset --hard main failed" seat-name))
            nil))
         (t
          (let ((res (funcall maduin-workspace--git-output-fn
                              wt "rebase" "main" branch)))
            (cond
             ((= 0 (car res)) 'synced)
             ((string-match-p "conflict" (downcase (or (cdr res) "")))
              (funcall maduin-workspace--git-fn wt "rebase" "--abort")
              (maduin-workspace--log-warning
               (format "sync seat %s: unlanded work on %s conflicts with main"
                       seat-name branch))
              'conflict)
             (t
              (funcall maduin-workspace--git-fn wt "rebase" "--abort")
              (maduin-workspace--log-warning
               (format "sync seat %s: rebase onto main failed (exit %d): %s"
                       seat-name (car res) (cdr res)))
              nil))))))
    (error
     (maduin-workspace--log-warning
      (format "sync seat %s: unexpected error: %s" seat-name err))
     nil)))

(defun maduin-workspace-cleanup (seat-name)
  "Remove SEAT-NAME worktree and branch; idempotent, never throws.
Return t on success or when there is nothing to clean (worktree dir
missing, branch already gone), nil when git operations fail.
Steps: 1) worktree missing → t; 2) verify branch exists from main
root; missing → t (skip delete); 3) `git worktree remove --force';
failure → warning + nil; 4) `git branch -D' from main root; failure
→ warning + nil; 5) `git worktree prune'; failure → warning only,
still t."
  (condition-case err
      (let* ((wt (maduin-workspace-path seat-name))
             (branch (maduin-workspace-branch seat-name))
             (main (funcall maduin-workspace--main-root-fn)))
        (if (not (file-directory-p wt))
            t
          (let ((verify (funcall maduin-workspace--git-output-fn
                                 main "rev-parse" "--verify" branch)))
            (if (/= 0 (car verify))
                t
              (if (/= 0 (funcall maduin-workspace--git-fn
                                 wt "worktree" "remove" "--force" wt))
                  (progn
                    (maduin-workspace--log-warning
                     (format "cleanup seat %s: worktree remove failed: %s"
                             seat-name wt))
                    nil)
                (if (/= 0 (funcall maduin-workspace--git-fn
                                   main "branch" "-D" branch))
                    (progn
                      (maduin-workspace--log-warning
                       (format "cleanup seat %s: branch -D failed for %s"
                               seat-name branch))
                      nil)
                  (progn
                    (when (/= 0 (funcall maduin-workspace--git-fn
                                         main "worktree" "prune"))
                      (maduin-workspace--log-warning
                       (format "cleanup seat %s: worktree prune failed (ignored)"
                               seat-name)))
                    t)))))))
    (error
     (maduin-workspace--log-warning
      (format "cleanup seat %s: unexpected error: %s" seat-name err))
     nil)))

(provide 'maduin-workspace)

;;; maduin-workspace.el ends here
