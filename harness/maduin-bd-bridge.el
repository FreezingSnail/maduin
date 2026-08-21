;;; maduin-bd-bridge.el --- Wrap bd CLI in elisp. -*- lexical-binding: t; -*-

;; All bd CLI interactions go through this file: single point for
;; mocking, error handling, logging.

(require 'cl-lib)
(require 'json)

;; maduin-logging.el may not exist yet; guard the require.
(require 'maduin-logging nil t)

;;;###autoload
(defcustom maduin-bd-close-file "output.md"
  "File name written by `maduin-bd-close' before closing the task.
The file is resolved under the close directory (a seat worktree) —
never the main repo root — so the root substrate-spike doc is not
clobbered."
  :type 'string
  :group 'maduin)

(defun maduin-bd--log-error (msg)
  "Log MSG as error via maduin-log if available, else `message'."
  (if (fboundp 'maduin-log)
      (maduin-log 'error msg)
    (message "[maduin-bd] ERROR: %s" msg)))

(defun maduin-bd--run (cmd)
  "Run CMD in shell. Return (exit-code . stdout-string).
Stderr is discarded so human error text never contaminates stdout."
  (with-temp-buffer
    (let ((code (call-process shell-file-name nil
                              (list (current-buffer) nil) nil
                              shell-command-switch cmd)))
      (cons code (buffer-string)))))

(defun maduin-bd--call (program &rest args)
  "Run PROGRAM directly with ARGS (no shell). Return (exit-code . stdout-string).
Stderr is discarded so human error text never contaminates stdout.
Args travel as a Lisp list — never interpolated into a shell string —
so task-ids and queries need no quoting and cannot be shell-injected."
  (with-temp-buffer
    (let ((code (apply #'call-process program nil
                       (list (current-buffer) nil) nil
                       args)))
      (cons code (buffer-string)))))

(defun maduin-bd--json-decode (s)
  "Decode JSON string S to alists and vectors, or nil on error.
Uses Emacs's native JSON parser when available and json.el otherwise."
  (condition-case nil
      (if (fboundp 'json-parse-string)
          (json-parse-string s :object-type 'alist :array-type 'array
                             :null-object nil :false-object nil)
        (json-read-from-string s))
    (error nil)))

(defun maduin-bd--json-data (output)
  "Parse OUTPUT as a JSON array; return list of alists, or nil.
Returns nil silently when OUTPUT is empty or not JSON (first
non-whitespace character is not `[' or `{')."
  (let ((s (string-trim (or output ""))))
    (when (and (not (string-empty-p s))
               (or (string-prefix-p "[" s) (string-prefix-p "{" s)))
      (let ((data (maduin-bd--json-decode s)))
        (when (vectorp data)
          (append data nil))))))

(defun maduin-bd--json-ids (output)
  "Extract `id' fields from JSON array OUTPUT. Return list of strings."
  (let ((data (maduin-bd--json-data output)))
    (when data
      (delq nil (mapcar (lambda (o)
                          (if (listp o) (alist-get 'id o) nil))
                        data)))))

(defun maduin-bd--deps (task-id)
  "Return list of dependency IDs for TASK-ID."
  (let ((res (maduin-bd--run
              (format "bd dep list %s --json" task-id))))
    (if (/= 0 (car res))
        (progn
          (maduin-bd--log-error
           (format "bd dep list %s failed (exit %d): %s"
                   task-id (car res) (cdr res)))
          nil)
      (maduin-bd--json-ids (cdr res)))))

;;; Public interface

(defun maduin-bd-ready-tasks ()
  "Return list of ready task ID strings (epics excluded)."
  (let ((res (maduin-bd--call "bd" "ready" "--exclude-type" "epic" "--json")))
    (if (/= 0 (car res))
        (progn
          (maduin-bd--log-error
           (format "bd ready failed (exit %d): %s" (car res) (cdr res)))
          nil)
      (maduin-bd--json-ids (cdr res)))))

(defun maduin-bd-list-all ()
  "Return all bd issues (any status) as normalized bead alists, or nil.
Issues a single `bd list --json --all' subprocess; callers derive
closed/in-progress/blocked counts client-side from each entry's
`status' field instead of issuing three `bd count --status' calls."
  (let ((res (maduin-bd--call "bd" "list" "--json" "--all")))
    (if (/= 0 (car res))
        (progn
          (maduin-bd--log-error
           (format "bd list --all failed (exit %d): %s" (car res) (cdr res)))
          nil)
      (maduin-bd--json-data (cdr res)))))

(defun maduin-bd-claim (task-id)
  "Claim TASK-ID via `bd update TASK-ID --claim'. Return t on success."
  (let ((res (maduin-bd--run
              (format "bd update %s --claim"
                      (shell-quote-argument task-id)))))
    (if (= 0 (car res))
        t
      (maduin-bd--log-error
       (format "bd update %s --claim failed (exit %d): %s"
               task-id (car res) (cdr res)))
      nil)))

(defun maduin-bd-release (task-id)
  "Release TASK-ID's claim: reset status to open.
Used when a session fails or a land errors non-conflict, so the task is
truly \"left open\" (returned to `bd ready') instead of staying claimed
in_progress forever.  Return t on success."
  (let ((res (maduin-bd--run
              (format "bd update %s --status open"
                      (shell-quote-argument task-id)))))
    (if (= 0 (car res))
        t
      (maduin-bd--log-error
       (format "bd update %s --status open failed (exit %d): %s"
               task-id (car res) (cdr res)))
      nil)))

(defun maduin-bd-close-path (&optional dir)
  "Return absolute path of `maduin-bd-close-file' under DIR.
DIR defaults to `default-directory'."
  (expand-file-name maduin-bd-close-file (or dir default-directory)))

(defun maduin-bd-close (task-id output &optional dir)
  "Write OUTPUT to `maduin-bd-close-file' inside DIR, then close TASK-ID.
DIR is the seat worktree (or any per-task directory); it defaults to
`default-directory'.  Return t on success."
  (let ((file (maduin-bd-close-path dir)))
    ;; Always write the file (empty when OUTPUT is nil) so the close's
    ;; `--reason-file' always exists — even in the worktree dir.
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert (or output "")))
    (let ((res (maduin-bd--run
                (format "bd close %s --reason-file %s" task-id file))))
      (if (= 0 (car res))
          t
        (maduin-bd--log-error
         (format "bd close %s failed (exit %d): %s"
                 task-id (car res) (cdr res)))
        nil))))

(defun maduin-bd-create-epic (title desc)
  "Create epic with TITLE and DESC. Return epic ID string or nil."
  (let ((res (maduin-bd--run
              (format "bd create %s --type epic --silent --description %s"
                      (shell-quote-argument title)
                      (shell-quote-argument desc)))))
    (if (= 0 (car res))
        (let ((id (string-trim (cdr res))))
          (if (string-empty-p id) nil id))
      (maduin-bd--log-error
       (format "bd create epic failed (exit %d): %s" (car res) (cdr res)))
      nil)))

(defun maduin-bd-create-task (title desc parent-id)
  "Create task with TITLE and DESC under PARENT-ID. Return task ID or nil."
  (let ((res (maduin-bd--run
              (format "bd create %s --type task --silent --description %s --parent %s"
                      (shell-quote-argument title)
                      (shell-quote-argument desc)
                      (shell-quote-argument parent-id)))))
    (if (= 0 (car res))
        (let ((id (string-trim (cdr res))))
          (if (string-empty-p id) nil id))
      (maduin-bd--log-error
       (format "bd create task failed (exit %d): %s" (car res) (cdr res)))
      nil)))

(defun maduin-bd-dep-add (task-id depends-on-id)
  "Add dependency TASK-ID depends on DEPENDS-ON-ID. Return t on success."
  (let ((res (maduin-bd--run
              (format "bd dep add %s %s"
                      (shell-quote-argument task-id)
                      (shell-quote-argument depends-on-id)))))
    (if (= 0 (car res))
        t
      (maduin-bd--log-error
       (format "bd dep add %s %s failed (exit %d): %s"
               task-id depends-on-id (car res) (cdr res)))
      nil)))

(defun maduin-bd-show (task-id)
  "Return plist (:title :desc :status :deps :parent) for TASK-ID, or nil."
  (let ((res (maduin-bd--call "bd" "show" task-id "--json")))
    (if (/= 0 (car res))
        (progn
          (maduin-bd--log-error
           (format "bd show %s failed (exit %d): %s"
                   task-id (car res) (cdr res)))
          nil)
      (let ((data (maduin-bd--json-data (cdr res))))
        (when data
          (list :title (alist-get 'title (car data))
                :desc (alist-get 'description (car data))
                :status (alist-get 'status (car data))
                :deps (maduin-bd--deps task-id)
                :parent (alist-get 'parent (car data))))))))

(defun maduin-bd-remember (fact)
  "Store FACT as persistent memory via `bd remember'. Return t on success."
  (let ((res (maduin-bd--run
              (format "bd remember %s" (shell-quote-argument fact)))))
    (if (= 0 (car res))
        t
      (maduin-bd--log-error
       (format "bd remember failed (exit %d): %s" (car res) (cdr res)))
      nil)))

(defun maduin-bd-prime ()
  "Run `bd prime'; return its context output as string."
  (let ((res (maduin-bd--run "bd prime")))
    (if (= 0 (car res))
        (cdr res)
      (maduin-bd--log-error
       (format "bd prime failed (exit %d): %s" (car res) (cdr res)))
      nil)))

;;; Approval gate wrappers

(defun maduin-bd-defer (id)
  "Defer ID indefinitely via `bd defer ID'. Return t on success."
  (let ((res (maduin-bd--run
              (format "bd defer %s" (shell-quote-argument id)))))
    (if (= 0 (car res))
        t
      (maduin-bd--log-error
       (format "bd defer %s failed (exit %d): %s"
               id (car res) (cdr res)))
      nil)))

(defun maduin-bd-undefer (id)
  "Undefer ID via `bd undefer ID'. Return t on success."
  (let ((res (maduin-bd--run
              (format "bd undefer %s" (shell-quote-argument id)))))
    (if (= 0 (car res))
        t
      (maduin-bd--log-error
       (format "bd undefer %s failed (exit %d): %s"
               id (car res) (cdr res)))
      nil)))

(defun maduin-bd-label (id label)
  "Add LABEL to ID via `bd label add ID LABEL'. Return t on success."
  (let ((res (maduin-bd--run
              (format "bd label add %s %s"
                      (shell-quote-argument id)
                      (shell-quote-argument label)))))
    (if (= 0 (car res))
        t
      (maduin-bd--log-error
       (format "bd label add %s %s failed (exit %d): %s"
               id label (car res) (cdr res)))
      nil)))

(defun maduin-bd-label-remove (id label)
  "Remove LABEL from ID via `bd label remove ID LABEL'. Return t on success."
  (let ((res (maduin-bd--run
              (format "bd label remove %s %s"
                      (shell-quote-argument id)
                      (shell-quote-argument label)))))
    (if (= 0 (car res))
        t
      (maduin-bd--log-error
       (format "bd label remove %s %s failed (exit %d): %s"
               id label (car res) (cdr res)))
      nil)))

(defun maduin-bd-query (q &optional all)
  "Return list of issue IDs matching Q via `bd query Q --json'.
When ALL is non-nil, include closed issues (`--all'; the CLI excludes
them by default).  Return nil on failure."
  (let ((res (apply #'maduin-bd--call
                    "bd" "query" q "--json"
                    (if all '("--all") nil))))
    (if (/= 0 (car res))
        (progn
          (maduin-bd--log-error
           (format "bd query %s failed (exit %d): %s"
                   q (car res) (cdr res)))
          nil)
      (maduin-bd--json-ids (cdr res)))))

(defun maduin-bd-open-epics ()
  "Return list of open epic ID strings, or nil.
Query `status=open AND type=epic' — epics the run-loop may still need
decomposing."
  (maduin-bd-query "status=open AND type=epic"))

(defun maduin-bd-in-progress-tasks ()
  "Return list of in_progress task ID strings, or nil.
Query `status=in_progress AND type=task' — tasks that were claimed but
may have been orphaned by an Emacs quit mid-task.  Dispatch recovery
uses this to re-dispatch stuck work."
  (maduin-bd-query "status=in_progress AND type=task"))

(defun maduin-bd-epic-children (epic)
  "Return list of child issue IDs under EPIC (any status), or nil.
Uses `--all' so a fully-implemented epic (all children closed) still
reports its children — otherwise the run-loop treats a done epic as
undecomposed and re-dispatches Ramuh decomposition."
  (maduin-bd-query (format "parent=%s" epic) t))

(defun maduin-bd-comment (id text)
  "Add TEXT as a comment on ID via `bd comment ID TEXT'. Return t on success."
  (let ((res (maduin-bd--run
              (format "bd comment %s %s"
                      (shell-quote-argument id)
                      (shell-quote-argument text)))))
    (if (= 0 (car res))
        t
      (maduin-bd--log-error
       (format "bd comment %s failed (exit %d): %s"
               id (car res) (cdr res)))
      nil)))

(defun maduin-bd-update-design-acceptance (id design acceptance)
  "Set ID's design and acceptance via `bd update ID --design --acceptance'.
Return t on success."
  (let ((res (maduin-bd--run
              (format "bd update %s --design %s --acceptance %s"
                      (shell-quote-argument id)
                      (shell-quote-argument design)
                      (shell-quote-argument acceptance)))))
    (if (= 0 (car res))
        t
      (maduin-bd--log-error
       (format "bd update %s (design/acceptance) failed (exit %d): %s"
               id (car res) (cdr res)))
      nil)))

;;; Worktree wrappers

(defun maduin-bd-worktree--entry (path branch)
  "Build (:path :branch :name) plist from PATH and BRANCH (may be nil)."
  (list :path path
        :branch branch
        :name (file-name-nondirectory (directory-file-name path))))

(defun maduin-bd-worktree--porcelain-entries (output)
  "Parse git worktree --porcelain OUTPUT into list of (:path :branch :name).
Handle detached worktrees (no branch line)."
  (let (entries cur-path cur-branch)
    (dolist (line (split-string output "\n"))
      (cond
       ((string-prefix-p "worktree " line)
        (when cur-path
          (push (maduin-bd-worktree--entry cur-path cur-branch)
                entries))
        (setq cur-path (string-trim (substring line 9))
              cur-branch nil))
       ((string-prefix-p "branch " line)
        (setq cur-branch
              (string-remove-prefix
               "refs/heads/"
               (string-trim (substring line 7)))))))
    (when cur-path
      (push (maduin-bd-worktree--entry cur-path cur-branch) entries))
    (nreverse entries)))

(defun maduin-bd-worktree--parse-created-path (output)
  "Extract worktree path from `bd worktree create' OUTPUT, or nil."
  (when (string-match "Created worktree: \\([^\n]+\\)" output)
    (string-trim (match-string 1 output))))

(defun maduin-bd-worktree-real-p (dir)
  "Return non-nil if DIR is a registered git worktree.
A real worktree resolves `git -C DIR rev-parse --show-toplevel' to DIR
itself (an empty or stale directory resolves to the main repo instead).
Symlinks are resolved via `file-truename' on both sides so path aliases
(e.g. a symlinked project root) do not yield false negatives."
  (let* ((d (directory-file-name (file-truename dir)))
         (res (maduin-bd--run
               (format "git -C %s rev-parse --show-toplevel"
                       (shell-quote-argument d)))))
    (and (= 0 (car res))
         (string= (directory-file-name
                   (file-truename (string-trim (cdr res))))
                  d))))

(defun maduin-bd-worktree-add (path &optional branch)
  "Create git worktree at PATH on new branch BRANCH via `git worktree add'.
BRANCH defaults to the basename of PATH.  Falls back to checking out an
existing BRANCH when creating a new one fails (branch may already exist).
Return PATH on success, nil on failure."
  (let* ((branch (or branch (file-name-nondirectory (directory-file-name path))))
         (res (maduin-bd--run
               (format "git worktree add %s -b %s"
                       (shell-quote-argument path)
                       (shell-quote-argument branch)))))
    (if (= 0 (car res))
        path
      ;; Branch may already exist from a prior attempt: check it out directly.
      (let ((res2 (maduin-bd--run
                   (format "git worktree add %s %s"
                           (shell-quote-argument path)
                           (shell-quote-argument branch)))))
        (if (= 0 (car res2))
            path
          (maduin-bd--log-error
           (format "git worktree add %s failed (exit %d): %s"
                   path (car res2) (cdr res2)))
          nil)))))

(defun maduin-bd-worktree-create (path &optional branch)
  "Create worktree at PATH via `bd worktree create PATH --branch BRANCH'.
BRANCH defaults to the basename of PATH.  Fall back to `git worktree add'
when bd fails or the result is not a real worktree.
Return worktree path string or nil."
  (let* ((branch (or branch (file-name-nondirectory (directory-file-name path))))
         (res (maduin-bd--run
                (format "bd worktree create %s --branch %s"
                        (shell-quote-argument path)
                        (shell-quote-argument branch)))))
    (if (= 0 (car res))
        (let ((created (or (maduin-bd-worktree--parse-created-path (cdr res))
                           path)))
          (if (maduin-bd-worktree-real-p created)
              created
            (maduin-bd--log-error
             (format "bd worktree create reported success but %s is not a real worktree; falling back to git"
                     created))
            (maduin-bd-worktree-add path branch)))
      (maduin-bd-worktree-add path branch))))

(defun maduin-bd-worktree-list ()
  "Return alist ((name . path) ...) from `bd worktree list'.
Use `bd worktree list --json'; fall back to `git worktree list --porcelain'."
  (let ((res (maduin-bd--run "bd worktree list --json")))
    (if (and (= 0 (car res))
             (maduin-bd--json-data (cdr res)))
        (let ((data (maduin-bd--json-data (cdr res))))
          (delq nil
                (mapcar (lambda (o)
                          (when (listp o)
                            (let ((name (alist-get 'name o))
                                  (path (alist-get 'path o)))
                              (when (and name path)
                                (cons name path)))))
                        data)))
      (maduin-bd--log-error
       (format "bd worktree list failed (exit %d): %s" (car res) (cdr res)))
      (let ((g (maduin-bd--run "git worktree list --porcelain")))
        (if (= 0 (car g))
            (mapcar (lambda (e)
                      (cons (plist-get e :name) (plist-get e :path)))
                    (maduin-bd-worktree--porcelain-entries (cdr g)))
          (maduin-bd--log-error
           (format "git worktree list failed (exit %d): %s" (car g) (cdr g)))
          nil)))))

(defun maduin-bd-worktree-info (dir)
  "Return plist (:path :branch :name) for worktree at DIR, or nil.
Runs `git -C DIR worktree list --porcelain'."
  (let* ((d (directory-file-name (expand-file-name dir)))
         (res (maduin-bd--run
               (format "git -C %s worktree list --porcelain"
                       (shell-quote-argument d)))))
    (if (/= 0 (car res))
        (progn
          (maduin-bd--log-error
           (format "git worktree list %s failed (exit %d): %s"
                   d (car res) (cdr res)))
          nil)
      (cl-find-if
       (lambda (e)
         (string= d (directory-file-name (plist-get e :path))))
       (maduin-bd-worktree--porcelain-entries (cdr res))))))

(provide 'maduin-bd-bridge)

;;; maduin-bd-bridge.el ends here
