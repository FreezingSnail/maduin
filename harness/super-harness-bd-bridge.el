;;; super-harness-bd-bridge.el --- Wrap bd CLI in elisp. -*- lexical-binding: t; -*-

;; All bd CLI interactions go through this file: single point for
;; mocking, error handling, logging.

(require 'cl-lib)
(require 'json)

;; super-harness-logging.el may not exist yet; guard the require.
(require 'super-harness-logging nil t)

;;;###autoload
(defcustom super-harness-bd-close-file "output.md"
  "File written by `super-harness-bd-close' before closing the task."
  :type 'string
  :group 'super-harness)

(defun super-harness-bd--log-error (msg)
  "Log MSG as error via super-harness-log if available, else `message'."
  (if (fboundp 'super-harness-log)
      (super-harness-log 'error msg)
    (message "[super-harness-bd] ERROR: %s" msg)))

(defun super-harness-bd--run (cmd)
  "Run CMD in shell. Return (exit-code . output-string)."
  (with-temp-buffer
    (let ((code (call-process shell-file-name nil t nil
                              shell-command-switch cmd)))
      (cons code (buffer-string)))))

(defun super-harness-bd--json-data (output)
  "Parse OUTPUT as JSON; return list of alists or nil on failure."
  (let ((data (condition-case err
                  (json-read-from-string output)
                (error
                 (super-harness-bd--log-error
                  (format "bd JSON parse failed: %s" err))
                 nil))))
    (when (vectorp data)
      (append data nil))))

(defun super-harness-bd--json-ids (output)
  "Extract `id' fields from JSON array OUTPUT. Return list of strings."
  (let ((data (super-harness-bd--json-data output)))
    (when data
      (delq nil (mapcar (lambda (o)
                          (if (listp o) (alist-get 'id o) nil))
                        data)))))

(defun super-harness-bd--deps (task-id)
  "Return list of dependency IDs for TASK-ID."
  (let ((res (super-harness-bd--run
              (format "bd dep list %s --json" task-id))))
    (if (/= 0 (car res))
        (progn
          (super-harness-bd--log-error
           (format "bd dep list %s failed (exit %d): %s"
                   task-id (car res) (cdr res)))
          nil)
      (super-harness-bd--json-ids (cdr res)))))

;;; Public interface

(defun super-harness-bd-ready-tasks ()
  "Return list of ready task ID strings (epics excluded)."
  (let ((res (super-harness-bd--run "bd ready --exclude-type epic --json")))
    (if (/= 0 (car res))
        (progn
          (super-harness-bd--log-error
           (format "bd ready failed (exit %d): %s" (car res) (cdr res)))
          nil)
      (super-harness-bd--json-ids (cdr res)))))

(defun super-harness-bd-claim (task-id)
  "Claim TASK-ID via `bd update TASK-ID --claim'. Return t on success."
  (let ((res (super-harness-bd--run
              (format "bd update %s --claim" task-id))))
    (if (= 0 (car res))
        t
      (super-harness-bd--log-error
       (format "bd update %s --claim failed (exit %d): %s"
               task-id (car res) (cdr res)))
      nil)))

(defun super-harness-bd-close (task-id output)
  "Write OUTPUT to `super-harness-bd-close-file', then close TASK-ID.
Return t on success."
  (let ((file super-harness-bd-close-file))
    (when (stringp output)
      (with-temp-file file (insert output)))
    (let ((res (super-harness-bd--run
                (format "bd close %s --reason-file %s" task-id file))))
      (if (= 0 (car res))
          t
        (super-harness-bd--log-error
         (format "bd close %s failed (exit %d): %s"
                 task-id (car res) (cdr res)))
        nil))))

(defun super-harness-bd-create-epic (title desc)
  "Create epic with TITLE and DESC. Return epic ID string or nil."
  (let ((res (super-harness-bd--run
              (format "bd create %s --type epic --silent --description %s"
                      (shell-quote-argument title)
                      (shell-quote-argument desc)))))
    (if (= 0 (car res))
        (let ((id (string-trim (cdr res))))
          (if (string-empty-p id) nil id))
      (super-harness-bd--log-error
       (format "bd create epic failed (exit %d): %s" (car res) (cdr res)))
      nil)))

(defun super-harness-bd-create-task (title desc parent-id)
  "Create task with TITLE and DESC under PARENT-ID. Return task ID or nil."
  (let ((res (super-harness-bd--run
              (format "bd create %s --type task --silent --description %s --parent %s"
                      (shell-quote-argument title)
                      (shell-quote-argument desc)
                      (shell-quote-argument parent-id)))))
    (if (= 0 (car res))
        (let ((id (string-trim (cdr res))))
          (if (string-empty-p id) nil id))
      (super-harness-bd--log-error
       (format "bd create task failed (exit %d): %s" (car res) (cdr res)))
      nil)))

(defun super-harness-bd-dep-add (task-id depends-on-id)
  "Add dependency TASK-ID depends on DEPENDS-ON-ID. Return t on success."
  (let ((res (super-harness-bd--run
              (format "bd dep add %s %s"
                      (shell-quote-argument task-id)
                      (shell-quote-argument depends-on-id)))))
    (if (= 0 (car res))
        t
      (super-harness-bd--log-error
       (format "bd dep add %s %s failed (exit %d): %s"
               task-id depends-on-id (car res) (cdr res)))
      nil)))

(defun super-harness-bd-show (task-id)
  "Return plist (:title :desc :status :deps) for TASK-ID, or nil."
  (let ((res (super-harness-bd--run
              (format "bd show %s --json" task-id))))
    (if (/= 0 (car res))
        (progn
          (super-harness-bd--log-error
           (format "bd show %s failed (exit %d): %s"
                   task-id (car res) (cdr res)))
          nil)
      (let ((data (super-harness-bd--json-data (cdr res))))
        (when data
          (list :title (alist-get 'title (car data))
                :desc (alist-get 'description (car data))
                :status (alist-get 'status (car data))
                :deps (super-harness-bd--deps task-id)))))))

(defun super-harness-bd-remember (fact)
  "Store FACT as persistent memory via `bd remember'. Return t on success."
  (let ((res (super-harness-bd--run
              (format "bd remember %s" (shell-quote-argument fact)))))
    (if (= 0 (car res))
        t
      (super-harness-bd--log-error
       (format "bd remember failed (exit %d): %s" (car res) (cdr res)))
      nil)))

(defun super-harness-bd-prime ()
  "Run `bd prime'; return its context output as string."
  (let ((res (super-harness-bd--run "bd prime")))
    (if (= 0 (car res))
        (cdr res)
      (super-harness-bd--log-error
       (format "bd prime failed (exit %d): %s" (car res) (cdr res)))
      nil)))

;;; Worktree wrappers

(defun super-harness-bd-worktree--entry (path branch)
  "Build (:path :branch :name) plist from PATH and BRANCH (may be nil)."
  (list :path path
        :branch branch
        :name (file-name-nondirectory (directory-file-name path))))

(defun super-harness-bd-worktree--porcelain-entries (output)
  "Parse git worktree --porcelain OUTPUT into list of (:path :branch :name).
Handle detached worktrees (no branch line)."
  (let (entries cur-path cur-branch)
    (dolist (line (split-string output "\n"))
      (cond
       ((string-prefix-p "worktree " line)
        (when cur-path
          (push (super-harness-bd-worktree--entry cur-path cur-branch)
                entries))
        (setq cur-path (string-trim (substring line 9))
              cur-branch nil))
       ((string-prefix-p "branch " line)
        (setq cur-branch
              (string-remove-prefix
               "refs/heads/"
               (string-trim (substring line 7)))))))
    (when cur-path
      (push (super-harness-bd-worktree--entry cur-path cur-branch) entries))
    (nreverse entries)))

(defun super-harness-bd-worktree--parse-created-path (output)
  "Extract worktree path from `bd worktree create' OUTPUT, or nil."
  (when (string-match "Created worktree: \\([^\n]+\\)" output)
    (string-trim (match-string 1 output))))

(defun super-harness-bd-worktree-create (name)
  "Create worktree NAME via `bd worktree create NAME --branch NAME'.
Return worktree path string or nil on failure."
  (let ((res (super-harness-bd--run
              (format "bd worktree create %s --branch %s"
                      (shell-quote-argument name)
                      (shell-quote-argument name)))))
    (if (= 0 (car res))
        (or (super-harness-bd-worktree--parse-created-path (cdr res))
            (cdr (assoc name (super-harness-bd-worktree-list))))
      (super-harness-bd--log-error
       (format "bd worktree create %s failed (exit %d): %s"
               name (car res) (cdr res)))
      nil)))

(defun super-harness-bd-worktree-list ()
  "Return alist ((name . path) ...) from `bd worktree list'.
Use `bd worktree list --json'; fall back to `git worktree list --porcelain'."
  (let ((res (super-harness-bd--run "bd worktree list --json")))
    (if (and (= 0 (car res))
             (super-harness-bd--json-data (cdr res)))
        (let ((data (super-harness-bd--json-data (cdr res))))
          (delq nil
                (mapcar (lambda (o)
                          (when (listp o)
                            (let ((name (alist-get 'name o))
                                  (path (alist-get 'path o)))
                              (when (and name path)
                                (cons name path)))))
                        data)))
      (super-harness-bd--log-error
       (format "bd worktree list failed (exit %d): %s" (car res) (cdr res)))
      (let ((g (super-harness-bd--run "git worktree list --porcelain")))
        (if (= 0 (car g))
            (mapcar (lambda (e)
                      (cons (plist-get e :name) (plist-get e :path)))
                    (super-harness-bd-worktree--porcelain-entries (cdr g)))
          (super-harness-bd--log-error
           (format "git worktree list failed (exit %d): %s" (car g) (cdr g)))
          nil)))))

(defun super-harness-bd-worktree-info (dir)
  "Return plist (:path :branch :name) for worktree at DIR, or nil.
Runs `git -C DIR worktree list --porcelain'."
  (let* ((d (directory-file-name (expand-file-name dir)))
         (res (super-harness-bd--run
               (format "git -C %s worktree list --porcelain"
                       (shell-quote-argument d)))))
    (if (/= 0 (car res))
        (progn
          (super-harness-bd--log-error
           (format "git worktree list %s failed (exit %d): %s"
                   d (car res) (cdr res)))
          nil)
      (cl-find-if
       (lambda (e)
         (string= d (directory-file-name (plist-get e :path))))
       (super-harness-bd-worktree--porcelain-entries (cdr res))))))

(provide 'super-harness-bd-bridge)

;;; super-harness-bd-bridge.el ends here
