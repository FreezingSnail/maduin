;;; super-harness.el --- main entry: minor mode, commands, keybindings  -*- lexical-binding: t; -*-

;;; Commentary:

;; Orchestrator entry point.  Defines the global minor mode
;; `super-harness-mode', the interactive user commands, and the
;; graceful-shutdown hook.  All heavy lifting lives in sibling
;; harness modules.

;;; Code:

(require 'cl-lib)

(defconst super-harness--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing super-harness.el.")

;; Ensure sibling harness modules resolve when loaded directly.
(add-to-list 'load-path super-harness--dir)

(require 'super-harness-config)
(require 'super-harness-session)
(require 'super-harness-agent)
(require 'super-harness-handoff)
(require 'super-harness-pipeline)
(require 'super-harness-cockpit)

;;; Minor mode

(defvar super-harness-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c s s") #'super-harness-status)
    (define-key map (kbd "C-c s a") #'super-harness-attach)
    (define-key map (kbd "C-c s c") #'super-harness-crew)
    map)
  "Keymap for `super-harness-mode'.")

;;;###autoload
(define-minor-mode super-harness-mode
  "Global minor mode for super-harness orchestration.
Provides commands to start, stop and monitor the agent fleet."
  :global t
  :lighter " SH"
  :keymap super-harness-mode-map)

;;; Config helpers

(defun super-harness--config-get (key &optional section)
  "Return config value for KEY in SECTION, or nil.
SECTION is a top-level config section symbol; when omitted, KEY is
looked up at the top level of `super-harness-config'."
  (let ((conf (bound-and-true-p super-harness-config)))
    (cdr (assq key (if section
                       (cdr (assq section conf))
                     conf)))))

(defun super-harness--seats ()
  "Return alist ((SEAT-NAME . ROLE) ...) from config (crew then fleet)."
  (append
   (mapcar (lambda (s) (cons (alist-get 'name s) "crew"))
           (super-harness--config-get 'seats 'crew))
   (mapcar (lambda (s) (cons (alist-get 'name s) "fleet"))
           (super-harness--config-get 'seats 'fleet))))

(defun super-harness--seat-model (seat role)
  "Return model configured for SEAT in ROLE section, or \"default\"."
  (let ((seats (super-harness--config-get 'seats role)))
    (or (and (listp seats)
             (alist-get 'model
                        (cl-find-if
                         (lambda (s) (string= (alist-get 'name s) seat))
                         seats)))
        "default")))

(defun super-harness--seat-workdir (seat)
  "Return workspace directory for SEAT under workspaces.path."
  (expand-file-name
   seat
   (expand-file-name
    (or (super-harness--config-get 'path 'workspaces)
        "harness/workspaces")
    default-directory)))

;;; Commands

;;;###autoload
(defun super-harness-start ()
  "Start all agents per config and open the cockpit.
For each crew seat: spawn an agent.  For each fleet seat: spawn an
agent and start its pipeline polling.  Then show and refresh the
cockpit dashboard."
  (interactive)
  (dolist (pair (super-harness--seats))
    (let* ((seat (car pair))
           (role (cdr pair))
           (model (super-harness--seat-model seat role))
           (workdir (super-harness--seat-workdir seat)))
      (make-directory workdir t)
      (super-harness-agent-spawn seat role model workdir)
      (when (string= role "fleet")
        (super-harness-pipeline-start-fleet seat))))
  (super-harness-cockpit-show)
  (super-harness-cockpit-refresh)
  (message "super-harness started"))

;;;###autoload
(defun super-harness-stop ()
  "Gracefully stop all agents and kill any remaining sessions.
Requests handoff from each agent, waits up to welfare.handoff-timeout,
then kills survivors.  Logs shutdown."
  (interactive)
  (super-harness-handoff-stop-all
   (super-harness--config-get 'handoff-timeout 'welfare))
  (dolist (pair (super-harness-session-list))
    (super-harness-session-kill (car pair)))
  (message "super-harness stopped"))

;;;###autoload
(defun super-harness-status ()
  "Refresh cockpit and show a summary message."
  (interactive)
  (super-harness-cockpit-refresh)
  (message "super-harness: %d sessions | %s"
           (length (super-harness-session-list))
           (super-harness-cockpit--pipeline-summary)))

;;;###autoload
(defun super-harness-restart ()
  "Stop then start all agents."
  (interactive)
  (super-harness-stop)
  (super-harness-start))

;;;###autoload
(defun super-harness-attach (seat)
  "Attach to SEAT's session buffer.
SEAT is chosen by completing-read from configured seats."
  (interactive
   (list (completing-read "Attach to seat: "
                          (mapcar #'car (super-harness--seats))
                          nil t)))
  (super-harness-session-switch seat))

;;;###autoload
(defun super-harness-crew (work)
  "Dispatch WORK text to the first free crew agent."
  (interactive "sCrew work: ")
  (super-harness-pipeline-dispatch-crew work))

;;;###autoload
(defun super-harness-bootstrap ()
  "First-time setup: create dirs and verify bd init.
Creates .agents/brain, .agents/handoff, .agents/logs and per-seat
workspace dirs.  Hints to run `bd init' when .beads is absent."
  (interactive)
  (dolist (dir '(".agents/brain" ".agents/handoff" ".agents/logs"))
    (make-directory dir t))
  (dolist (pair (super-harness--seats))
    (make-directory (super-harness--seat-workdir (car pair)) t))
  (if (file-exists-p ".beads")
      (message "super-harness: bootstrap done")
    (message "super-harness: bootstrap done; hint: run `bd init` (no .beads found)")))

;;; Shutdown hook

(add-hook 'kill-emacs-hook #'super-harness-stop)

(provide 'super-harness)

;;; super-harness.el ends here
