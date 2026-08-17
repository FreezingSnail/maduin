;;; maduin-pipeline.el --- concierge/designer/implementer pipeline  -*- lexical-binding: t; -*-

;;; Commentary:

;; Config/seat access, branch landing and pipeline status.  Spawn,
;; dispatch and concurrency now live in maduin-dispatch.el (demand-
;; driven ephemeral sessions); this file is the single source of truth
;; for `maduin-pipeline-land-branch', seat lists and `maduin-pipeline-status'.

;;; Code:

(defconst maduin-pipeline--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing maduin-pipeline.el.")

(add-to-list 'load-path maduin-pipeline--dir)

(require 'cl-lib)
(require 'maduin-bd-bridge)
(require 'maduin-config)
(require 'maduin-workspace)

;;; Config access

(defun maduin-pipeline--config ()
  "Return the maduin config alist.
Load harness/config.el explicitly because maduin-config.el
is a stub and the real values live there."
  (or (bound-and-true-p maduin-config)
      (condition-case nil
          (progn
            (load-file (expand-file-name "config.el" maduin-pipeline--dir))
            (bound-and-true-p maduin-config))
        (error nil))))

(defun maduin-pipeline--config-section (section)
  "Return alist for SECTION of maduin config, or nil."
  (cdr (assq section (maduin-pipeline--config))))

(defun maduin-pipeline--config-get (section key)
  "Return value of KEY in SECTION of maduin config, or nil."
  (cdr (assq key (maduin-pipeline--config-section section))))

;;; Seats

(defun maduin-pipeline-fleet-seats ()
  "Return list of fleet seat names from config."
  (delq nil
        (mapcar (lambda (s)
                  (when (listp s) (alist-get 'name s)))
                (maduin-pipeline--config-get 'fleet 'seats))))

(defun maduin-pipeline--concierge-seats ()
  "Return list of concierge seat names from config."
  (delq nil
        (mapcar (lambda (s)
                  (when (listp s) (alist-get 'name s)))
                (maduin-pipeline--config-get 'concierge 'seats))))

(defun maduin-pipeline--designer-seats ()
  "Return list of designer seat names from config."
  (delq nil
        (mapcar (lambda (s)
                  (when (listp s) (alist-get 'name s)))
                (maduin-pipeline--config-get 'designer 'seats))))

;;; Branch landing

(defun maduin-pipeline--git (dir &rest args)
  "Run `git -C DIR ARGS...' via shell; return exit status.
Output is discarded.  Uses `call-process-shell-command' so the
exit status is available programmatically."
  (let ((default-directory dir)
        (cmd (format "git -C %s %s"
                     (shell-quote-argument dir)
                     (mapconcat #'shell-quote-argument args " "))))
    (call-process-shell-command cmd nil nil)))

(defun maduin-pipeline--main-root ()
  "Return main maduin repo root.
Prefer the directory containing maduin.el, else
`default-directory'."
  (or (and (locate-library "maduin")
           (file-name-directory (locate-library "maduin")))
      (expand-file-name default-directory)))

(defun maduin-pipeline--git-output (dir &rest args)
  "Run `git -C DIR ARGS...'; return (STATUS . OUTPUT)."
  (let* ((default-directory dir)
         (cmd (format "git -C %s %s"
                      (shell-quote-argument dir)
                      (mapconcat #'shell-quote-argument args " ")))
         (buf (get-buffer-create " *maduin-pipeline-git*")))
    (with-current-buffer buf (erase-buffer))
    (cons (call-process-shell-command cmd nil buf)
          (with-current-buffer buf (buffer-string)))))

(defvar maduin-pipeline--worktree-path-fn #'maduin-workspace-path
  "Function `(seat)' → worktree directory.  Injection seam for tests.")

(defvar maduin-pipeline--branch-fn #'maduin-workspace-branch
  "Function `(seat)' → seat branch name.  Injection seam for tests.")

(defvar maduin-pipeline--main-root-fn #'maduin-pipeline--main-root
  "Function `()' → main repo root.  Injection seam for tests.")

(defvar maduin-pipeline--git-fn #'maduin-pipeline--git
  "Function `(dir &rest args)' → exit status.  Injection seam for tests.")

(defvar maduin-pipeline--git-output-fn #'maduin-pipeline--git-output
  "Function `(dir &rest args)' → (STATUS . OUTPUT).  Injection seam for tests.")

(defun maduin-pipeline-land-branch (seat-name)
  "Commit SEAT-NAME worktree changes and merge its branch into main.
Return t on successful merge (or when the seat branch is already an
ancestor of main), \\='conflict when the merge failed and output
indicates a conflict, nil on other failures (missing worktree, commit
failure, missing seat branch, non-conflict merge failure; logged, never
forced).  Steps: add -A in worktree; commit staged changes (\"nothing to
commit\" is not a failure); skip the merge only when the seat branch is
already an ancestor of main (`git merge-base --is-ancestor HEAD main');
otherwise verify the seat branch exists (`git rev-parse --verify') and
`git merge --no-ff' the seat branch from the main repo."
  (let* ((wt (funcall maduin-pipeline--worktree-path-fn seat-name))
         (branch (funcall maduin-pipeline--branch-fn seat-name))
         (main (funcall maduin-pipeline--main-root-fn)))
    (if (not (file-directory-p wt))
        (progn
          (maduin-workspace--log-warning
           (format "land-branch: worktree %s missing for seat %s" wt seat-name))
          nil)
      (funcall maduin-pipeline--git-fn wt "add" "-A")
      (let ((res (funcall maduin-pipeline--git-output-fn
                          wt "commit" "-m"
                          (format "task complete (%s)" seat-name))))
        (if (and (/= 0 (car res))
                 (not (string-match-p "nothing to commit" (cdr res))))
            (progn
              (maduin-workspace--log-warning
               (format "land-branch: commit failed (exit %d): %s"
                       (car res) (cdr res)))
              nil)
          ;; Commit done (or nothing to commit).  Skip the merge only when
          ;; the seat branch (worktree HEAD) is already an ancestor of main.
          (if (= 0 (funcall maduin-pipeline--git-fn
                            wt "merge-base" "--is-ancestor" "HEAD" "main"))
              t
            ;; Verify the seat branch exists before merging; log and bail
            ;; when it doesn't.
            (let ((verify (funcall maduin-pipeline--git-output-fn
                                   main "rev-parse" "--verify" branch)))
              (if (/= 0 (car verify))
                  (progn
                    (maduin-workspace--log-warning
                     (format "land-branch: seat branch %s not found (exit %d): %s"
                             branch (car verify) (cdr verify)))
                    nil)
                (let ((res (funcall maduin-pipeline--git-output-fn
                                    main "merge" "--no-ff" branch
                                    "-m" (format "land %s" seat-name))))
                  (if (= 0 (car res))
                      t
                    ;; Distinguish conflict from other merge failures:
                    ;; git prints "CONFLICT (content): ..." / "fix conflicts".
                    (if (string-match-p "conflict" (downcase (cdr res)))
                        (progn
                          ;; Abort the failed merge so main is left clean.
                          ;; Otherwise main stays on a conflicted MERGE_HEAD
                          ;; and a later land (or the repairer's own merge)
                          ;; jams against the half-finished merge.
                          (funcall maduin-pipeline--git-fn main "merge" "--abort")
                          'conflict)
                      (maduin-workspace--log-warning
                       (format "land-branch: merge of %s into main failed (exit %d): %s"
                               branch (car res) (cdr res)))
                      nil)))))))))))

;;; Status

(defun maduin-pipeline--count (status)
  "Return bd issue count with STATUS via `bd count', or 0."
  (let* ((res (maduin-bd--run
               (format "bd count --status %s --json" status)))
         (data (and (= 0 (car res))
                    (maduin-bd--json-data (cdr res)))))
    (or (and data (alist-get 'count (car data))) 0)))

(defun maduin-pipeline--fleet-busy-count ()
  "Return number of in-flight fleet (implementer) sessions.
Reads `maduin-dispatch--active' — the demand-driven dispatch registry,
the source of truth for in-flight work.  Returns 0 when dispatch is
not loaded (pipeline may load standalone)."
  (if (boundp 'maduin-dispatch--active)
      (cl-count-if (lambda (e) (eq (plist-get e :role) 'implementer))
                   maduin-dispatch--active)
    0))

(defun maduin-pipeline-status ()
  "Return plist (:queued :active :completed :blocked :fleet-free :fleet-busy)."
  (let* ((fleet (maduin-pipeline-fleet-seats))
         (busy (maduin-pipeline--fleet-busy-count)))
    (list :queued (length (or (maduin-bd-ready-tasks) nil))
          :active (maduin-pipeline--count "in-progress")
          :completed (maduin-pipeline--count "closed")
          :blocked (maduin-pipeline--count "blocked")
          :fleet-free (- (length fleet) busy)
          :fleet-busy busy)))

(provide 'maduin-pipeline)

;;; maduin-pipeline.el ends here
