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
(require 'maduin-bd-async)
(require 'maduin-bd-bridge)
(require 'maduin-config)
(require 'maduin-state)
(require 'maduin-workspace)

;;; Config access

(defvar maduin-pipeline--config-generation 0
  "Generation of memoized pipeline configuration and seat lists.")

(defvar maduin-pipeline--config-cache nil
  "Cached `(GENERATION . CONFIG)' pair, or nil before the first read.")

(defvar maduin-pipeline--seats-cache nil
  "Cached `(GENERATION . RESULT-PLIST)' pair for seat names.")

(defun maduin-pipeline-config-bump ()
  "Invalidate memoized pipeline configuration after a config mutation."
  (setq maduin-pipeline--config-generation
        (1+ maduin-pipeline--config-generation)
        maduin-pipeline--config-cache nil
        maduin-pipeline--seats-cache nil))

(defun maduin-pipeline--config ()
  "Return the memoized maduin config alist.
Load harness/config.el once only when `maduin-config' is not already bound."
  (let ((cached maduin-pipeline--config-cache))
    (if (and (consp cached)
             (= (car cached) maduin-pipeline--config-generation))
        (cdr cached)
      (let ((loaded nil)
            (config (bound-and-true-p maduin-config)))
        (unless config
          (setq loaded t
                config
                (condition-case nil
                    (progn
                      (load-file (expand-file-name "config.el" maduin-pipeline--dir))
                      (bound-and-true-p maduin-config))
                  (error nil))))
        (when loaded
          (maduin-pipeline-config-bump))
        (setq maduin-pipeline--config-cache
              (cons maduin-pipeline--config-generation config))
        config))))

(defun maduin-pipeline--config-section (section)
  "Return alist for SECTION of memoized maduin config, or nil."
  (cdr (assq section (maduin-pipeline--config))))

(defun maduin-pipeline--config-get (section key)
  "Return value of KEY in SECTION of memoized maduin config, or nil."
  (cdr (assq key (maduin-pipeline--config-section section))))

;;; Seats

(defun maduin-pipeline--seats (section)
  "Return memoized seat names configured in SECTION."
  (let* ((cached maduin-pipeline--seats-cache)
         (result (if (and (consp cached)
                          (= (car cached) maduin-pipeline--config-generation))
                     (cdr cached)
                   nil)))
    (unless (and result (plist-member result section))
      (let ((seats (delq nil
                          (mapcar (lambda (seat)
                                    (when (listp seat) (alist-get 'name seat)))
                                  (maduin-pipeline--config-get section 'seats)))))
        (setq result (plist-put result section seats)
              maduin-pipeline--seats-cache
              (cons maduin-pipeline--config-generation result))))
    (plist-get result section)))

(defun maduin-pipeline-fleet-seats ()
  "Return memoized list of fleet seat names from config."
  (maduin-pipeline--seats 'fleet))

(defun maduin-pipeline--concierge-seats ()
  "Return memoized list of concierge seat names from config."
  (maduin-pipeline--seats 'concierge))

(defun maduin-pipeline--designer-seats ()
  "Return memoized list of designer seat names from config."
  (maduin-pipeline--seats 'designer))

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
  "Commit SEAT-NAME worktree changes, rebase its branch onto main, then
fast-forward main to the rebased branch tip.
Return t on success, \\='conflict when the rebase failed and output
indicates a conflict, nil on other failures (missing worktree, commit
failure, missing seat branch, non-conflict rebase failure, failed
fast-forward; logged, never forced).  Rebasing onto the current main
guarantees the branch contains all of main's latest, so the merge can
only add — never revert.  Conflicts are detected at the rebase step
(not the merge step).  Steps: add -A in worktree; commit staged changes
(\"nothing to commit\" is not a failure); verify the seat branch exists
(`git rev-parse --verify'); `git rebase main <branch>' from the main
repo (aborting and returning \\='conflict on a conflict); then
`git merge --ff-only <branch>' from the main repo."
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
          ;; Commit done (or nothing to commit).  Verify the seat branch
          ;; exists before rebasing; log and bail when it doesn't.
          (let ((verify (funcall maduin-pipeline--git-output-fn
                                 main "rev-parse" "--verify" branch)))
            (if (/= 0 (car verify))
                (progn
                  (maduin-workspace--log-warning
                   (format "land-branch: seat branch %s not found (exit %d): %s"
                           branch (car verify) (cdr verify)))
                  nil)
              ;; Rebase the branch onto current main so it contains all of
              ;; main's latest; its merge can only add, never revert.
              (let ((res (funcall maduin-pipeline--git-output-fn
                                  main "rebase" "main" branch)))
                (cond
                 ((= 0 (car res))
                  ;; Rebase clean (a branch already containing main is a
                  ;; no-op rebase that still exits 0).  Fast-forward main.
                  (let ((ff (funcall maduin-pipeline--git-output-fn
                                     main "merge" "--ff-only" branch)))
                    (if (= 0 (car ff))
                        t
                      (maduin-workspace--log-warning
                       (format "land-branch: merge --ff-only %s failed (exit %d): %s"
                               branch (car ff) (cdr ff)))
                      nil)))
                 ((string-match-p "conflict" (downcase (cdr res)))
                  ;; Rebase conflict: abort so main is left clean and the
                  ;; branch is back to its pre-rebase state.
                  (funcall maduin-pipeline--git-fn main "rebase" "--abort")
                  'conflict)
                 (t
                  (maduin-workspace--log-warning
                   (format "land-branch: rebase of %s onto main failed (exit %d): %s"
                           branch (car res) (cdr res)))
                  nil))))))))))

(defun maduin-pipeline-landed-p (seat-name)
  "Return non-nil when SEAT-NAME's branch tip is an ancestor of main.
Uses `git merge-base --is-ancestor <branch> main` from the main repo."
  (let* ((branch (funcall maduin-pipeline--branch-fn seat-name))
         (main (funcall maduin-pipeline--main-root-fn)))
    (condition-case nil
        (= 0 (funcall maduin-pipeline--git-fn
                      main "merge-base" "--is-ancestor" branch "main"))
      (error nil))))

;;; Status

(defun maduin-pipeline--count (data status)
  "Return number of alists in DATA whose `status' equals STATUS.
DATA is the normalized result of `maduin-bd-list-all' (one subprocess),
so callers count without extra bd calls.  STATUS must be a stored bd
status string (e.g. \"in_progress\", \"closed\", \"blocked\")."
  (cl-count-if (lambda (o) (equal (alist-get 'status o) status))
               (or data nil)))

(defun maduin-pipeline--fleet-busy-count ()
  "Return number of in-flight fleet (implementer) sessions.
Reads `maduin-dispatch--active' — the demand-driven dispatch registry,
the source of truth for in-flight work.  Returns 0 when dispatch is
not loaded (pipeline may load standalone)."
  (if (boundp 'maduin-dispatch--active)
      (cl-count-if (lambda (e) (eq (plist-get e :role) 'implementer))
                   maduin-dispatch--active)
    0))

(defvar maduin-pipeline--status-refreshing nil
  "Non-nil while one pipeline status refresh awaits its async results.")

(defun maduin-pipeline--status-plist (queued data)
  "Build a pipeline status plist from QUEUED ready tasks and issue DATA."
  (let* ((fleet (maduin-pipeline-fleet-seats))
         (busy (maduin-pipeline--fleet-busy-count)))
    (list :queued (length (or queued nil))
          :active (maduin-pipeline--count data "in_progress")
          :completed (maduin-pipeline--count data "closed")
          :blocked (maduin-pipeline--count data "blocked")
          :fleet-free (- (length fleet) busy)
          :fleet-busy busy)))

(defun maduin-pipeline--empty-status ()
  "Return the safe initial pipeline status before the first fetch."
  (maduin-pipeline--status-plist nil nil))

(defun maduin-pipeline-status ()
  "Return the current pipeline snapshot without performing bd I/O."
  (or (maduin-state-get 'pipeline)
      (maduin-pipeline--empty-status)))

(defun maduin-pipeline-status-sync ()
  "Return a fresh pipeline status using the legacy blocking bd calls.
This compatibility entry point is intended for batch callers and first-paint
priming; interactive rendering should use `maduin-pipeline-status'."
  (maduin-pipeline--status-plist (maduin-bd-ready-tasks)
                                 (maduin-bd-list-all)))

(defun maduin-pipeline--status-callback (callback changed)
  "Run CALLBACK when CHANGED, containing errors from callback bodies."
  (when (and changed callback)
    (condition-case err
        (funcall callback)
      (error
       (maduin-bd--log-error
        (format "pipeline status callback failed: %s"
                (error-message-string err)))))))

(defun maduin-pipeline-status-refresh (&optional callback)
  "Asynchronously refresh the pipeline snapshot and then call CALLBACK.
A fresh snapshot, or an already-running refresh, starts no processes.  Both
bd results must succeed before a single merged snapshot is stored."
  (when (and (not maduin-pipeline--status-refreshing)
             (maduin-state-stale-p 'pipeline))
    (let ((pending 2)
          (failed nil)
          ready-data
          list-data)
      (setq maduin-pipeline--status-refreshing t)
      (cl-labels
          ((finish
            (kind data exit-code)
            (unless (and (= exit-code 0) data)
              (setq failed t)
              (maduin-bd--log-error
               (format "pipeline status %s fetch failed%s"
                       kind
                       (if (= exit-code 0) " (invalid JSON)"
                         (format " (exit %d)" exit-code)))))
            (when (and (= exit-code 0) data)
              (if (eq kind 'ready)
                  (setq ready-data data)
                (setq list-data data)))
            (setq pending (1- pending))
            (when (zerop pending)
              (setq maduin-pipeline--status-refreshing nil)
              (unless failed
                (let* ((previous (maduin-state-get 'pipeline))
                       (snapshot (maduin-pipeline--status-plist ready-data list-data))
                       (changed (not (equal previous snapshot))))
                  (maduin-state-put 'pipeline snapshot)
                  (maduin-pipeline--status-callback callback changed)))))
           (start
            (kind args)
            (let ((called nil))
              (let ((key (maduin-bd-async-json
                          args
                          (lambda (data exit-code)
                            (setq called t)
                            (finish kind data exit-code)))))
                ;; Spawn failures do not call their callback.  Count them as
                ;; failed immediately so the next stale tick retries.
                (unless (or key called)
                  (finish kind nil 1))))))
        (start 'ready '("ready" "--exclude-type" "epic" "--json"))
        (start 'list '("list" "--json" "--all"))))))

(provide 'maduin-pipeline)

;;; maduin-pipeline.el ends here
