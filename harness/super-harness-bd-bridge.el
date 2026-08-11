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

(provide 'super-harness-bd-bridge)

;;; super-harness-bd-bridge.el ends here
