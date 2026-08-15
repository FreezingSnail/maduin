;;; maduin-designer.el --- Ramuh: PDD research + design/acceptance + stage  -*- lexical-binding: t; -*-

;;; Commentary:

;; Designer role (Ramuh).  Phase B of PDD: for each deferred high-level
;; task, run an autonomous design session that researches unknowns,
;; fills the task's --design + --acceptance fields, and stages it for
;; review (defer + "staged" label).
;;
;; Division of labour:
;;   - The designer OWNS the prompt/plan content (templates/designer-prompt.txt).
;;   - maduin-dispatch OWNS spawn/concurrency (claim, seat pick, session run).
;;
;; Staging is NOT reimplemented here: the design session performs it via
;; bd CLI (defer + label staged), mirroring `maduin-gate-stage' (which
;; remains the deterministic elisp API used by the approval gate).
;;
;; Drop-in: `maduin-designer-drop-in' opens a live TUI on the Ramuh seat
;; so the Summoner can clarify a design mid-flight.

;;; Code:

(require 'cl-lib)

(defconst maduin-designer--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing maduin-designer.el.")

(add-to-list 'load-path maduin-designer--dir)

(require 'maduin-config)
(require 'maduin-bd-bridge)
(require 'maduin-dispatch)
(require 'maduin-terminal)

;;; Injection seams (function-valued defvars; tests let-bind these).

(defvar maduin-designer--show-fn #'maduin-bd-show
  "Function `(task)' → plist (:title :desc :status :deps) | nil.")

(defvar maduin-designer--query-fn #'maduin-bd-query
  "Function `(q)' → list of issue ids | nil.")

(defvar maduin-designer--has-design-fn #'maduin-designer--has-design
  "Function `(task)' → non-nil when the task has a non-empty --design.")

(defvar maduin-designer--dispatch-fn #'maduin-dispatch-design
  "Function `(task plan)' → session handle | nil.")

(defvar maduin-designer--terminal-open-fn #'maduin-terminal-open
  "Function `(seat role model)' → terminal buffer.")

;;; Prompt template

(defun maduin-designer--template ()
  "Return the designer prompt template text, or nil when missing."
  (let ((path (expand-file-name "templates/designer-prompt.txt"
                                maduin-designer--dir)))
    (when (and (file-exists-p path) (file-readable-p path))
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string)))))

(defun maduin-designer--prompt (task)
  "Build the design prompt for TASK.
Read templates/designer-prompt.txt and substitute {id}/{title}/{desc}.
The title/desc come from show-fn; the template owns the directives."
  (let* ((spec (condition-case nil
                   (funcall maduin-designer--show-fn task)
                 (error nil)))
         (tmpl (or (maduin-designer--template) ""))
         (out (replace-regexp-in-string "{id}" task tmpl t t)))
    (setq out (replace-regexp-in-string
               "{title}" (or (plist-get spec :title) "") out t t))
    (replace-regexp-in-string
     "{desc}" (or (plist-get spec :desc) "") out t t)))

;;; Design dispatch

(defun maduin-designer-design (task &optional plan)
  "Design TASK: dispatch a Ramuh session with the design prompt.
Return the session handle, or nil when busy or spawn fails.  PLAN, when
given, overrides the built prompt."
  (funcall maduin-designer--dispatch-fn task
           (or plan (maduin-designer--prompt task))))

;;; Drop-in TUI

(defun maduin-designer--seat-model (role seat)
  "Return model for ROLE/SEAT from `maduin-config', or \"default\"."
  (let* ((section (cdr (assq role maduin-config)))
         (seats (cdr (assq 'seats section)))
         (entry (and (listp seats)
                     (cl-find-if (lambda (s) (string= (alist-get 'name s) seat))
                                 seats))))
    (or (and entry (alist-get 'model entry)) "default")))

(defun maduin-designer-drop-in (seat)
  "Open a live TUI on SEAT for Summoner clarification mid-design.
Role `designer'; model resolved from config.  Return the terminal buffer."
  (interactive
   (list (completing-read
          "Designer seat: "
          (mapcar (lambda (s) (alist-get 'name s))
                  (cdr (assq 'seats (cdr (assq 'designer maduin-config))))))))
  (funcall maduin-designer--terminal-open-fn seat 'designer
           (maduin-designer--seat-model 'designer seat)))

;;; Pending tasks

(defun maduin-designer--has-design (id)
  "Return non-nil when task ID has a non-empty --design field.
`bd show --json' does not expose design, so parse the human-readable
`bd show ID' output for the DESIGN section header."
  (let ((res (maduin-bd--run
              (format "bd show %s" (shell-quote-argument id)))))
    (and res
         (= 0 (car res))
         (string-match-p "\nDESIGN[ \t]*\n" (cdr res)))))

(defun maduin-designer-pending-tasks ()
  "Return list of deferred task IDs lacking a --design field.
Query `status=deferred AND type=task', then drop tasks that already
have a design (checked via `bd show').  Interactively, message the list."
  (interactive)
  (let ((pending (cl-remove-if
                  (lambda (id)
                    (funcall maduin-designer--has-design-fn id))
                  (or (funcall maduin-designer--query-fn
                               "status=deferred AND type=task")
                      nil))))
    (when (called-interactively-p 'any)
      (if pending
          (message "pending design tasks: %s" (mapconcat #'identity pending ", "))
        (message "no tasks pending design")))
    pending))

(provide 'maduin-designer)

;;; maduin-designer.el ends here
