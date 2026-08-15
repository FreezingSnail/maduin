;;; maduin-concierge.el --- concierge (Alexander): epic discussion TUI  -*- lexical-binding: t; -*-

;;; Commentary:

;; Concierge role (Alexander) — the Summoner's single point of contact.
;; Summoned on demand per epic discussion via the interactive opencode TUI
;; (maduin-terminal.el); dismissed after the epic is hashed out.  The
;; session is NOT persistent — continuity flows through the export →
;; handoff note written by `maduin-terminal-dismiss'.
;;
;; The concierge captures the Summoner's idea into an epic and files it
;; plus HIGH-LEVEL (deferred) tasks in bd — via its own bd calls inside
;; the TUI, not here.  This module only opens/prises the TUI and dismisses
;; it.  Detailed design is Ramuh's job, later.

;;; Code:

(require 'cl-lib)

(defconst maduin-concierge--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing maduin-concierge.el.")

;; Ensure sibling harness modules resolve when loaded directly.
(add-to-list 'load-path maduin-concierge--dir)

(require 'maduin-config)
(require 'maduin-terminal)

;;; Injection seams (function-valued defvars; tests let-bind these).

(defvar maduin-concierge--terminal-open-fn #'maduin-terminal-open
  "Function `(seat role model)' → terminal buffer.")

(defvar maduin-concierge--terminal-dismiss-fn #'maduin-terminal-dismiss
  "Function `(seat)' → handoff note string | nil.")

;;; Seat + model resolution

(defvar maduin-concierge--seat "alexander"
  "Concierge seat name.")

(defun maduin-concierge--seat-model (seat)
  "Return model configured for concierge SEAT, or \"default\"."
  (let* ((seats (cdr (assq 'seats (cdr (assq 'concierge maduin-config)))))
         (entry (and (listp seats)
                     (cl-find-if (lambda (s)
                                   (string= (alist-get 'name s) seat))
                                 seats))))
    (or (and entry (alist-get 'model entry)) "default")))

(defun maduin-concierge--model ()
  "Return the concierge seat model."
  (maduin-concierge--seat-model maduin-concierge--seat))

;;; Public interface

;;;###autoload
(defun maduin-concierge ()
  "Summon the concierge (Alexander) in an interactive opencode TUI.
Opens the terminal buffer primed with the concierge role template so the
Summoner can hash out an epic into HIGH-LEVEL (deferred) bd tasks.
Return the terminal buffer."
  (interactive)
  (funcall maduin-concierge--terminal-open-fn
           maduin-concierge--seat 'concierge (maduin-concierge--model)))

;;;###autoload
(defun maduin-concierge-dismiss ()
  "Dismiss the concierge session for `maduin-concierge--seat'.
Export the conversation to a handoff note and kill the TUI buffer (via
`maduin-terminal-dismiss').  The epic + high-level tasks are filed in bd
by the concierge during the session.  Return the handoff note, or nil."
  (interactive)
  (let ((note (funcall maduin-concierge--terminal-dismiss-fn
                       maduin-concierge--seat)))
    (when note
      (message "maduin: concierge handoff written for %s"
               maduin-concierge--seat))
    note))

(provide 'maduin-concierge)

;;; maduin-concierge.el ends here
