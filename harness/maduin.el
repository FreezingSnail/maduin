;;; maduin.el --- main entry: minor mode, commands, keybindings  -*- lexical-binding: t; -*-

;;; Commentary:

;; Orchestrator entry point.  Defines the global minor mode
;; `maduin-mode', the interactive user commands, and the
;; graceful-shutdown hook.  All heavy lifting lives in sibling
;; harness modules.

;;; Code:

(require 'cl-lib)

(defconst maduin--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing maduin.el.")

;; Ensure sibling harness modules resolve when loaded directly.
(add-to-list 'load-path maduin--dir)

(require 'maduin-config)
(require 'maduin-session)
(require 'maduin-agent)
(require 'maduin-handoff)
(require 'maduin-pipeline)
(require 'maduin-workspace)
(require 'maduin-resolver)
(require 'maduin-terminal)
(require 'maduin-concierge)
(require 'maduin-cockpit)
(require 'maduin-gate)

;;; Minor mode

(defvar maduin-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c s s") #'maduin-status)
    (define-key map (kbd "C-c s a") #'maduin-attach)
    (define-key map (kbd "C-c s c") #'maduin-concierge)
    (define-key map (kbd "C-c s d") #'maduin-concierge-dismiss)
    map)
  "Keymap for `maduin-mode'.")

;;;###autoload
(define-minor-mode maduin-mode
  "Global minor mode for maduin orchestration.
Provides commands to start, stop and monitor the agent fleet."
  :global t
  :lighter " SH"
  :keymap maduin-mode-map)

;;; Config helpers

(defun maduin--config-get (key &optional section)
  "Return config value for KEY in SECTION, or nil.
SECTION is a top-level config section symbol; when omitted, KEY is
looked up at the top level of `maduin-config'."
  (let ((conf (bound-and-true-p maduin-config)))
    (cdr (assq key (if section
                       (cdr (assq section conf))
                     conf)))))

(defun maduin--seats ()
  "Return alist ((SEAT-NAME . ROLE) ...) from config seats.
Sections: concierge, designer, fleet.  ROLE is each seat's `role'
field coerced to a string (concierge/designer/implementer)."
  (cl-loop for section in '(concierge designer fleet)
           append (mapcar (lambda (s)
                            (cons (alist-get 'name s)
                                  (symbol-name (alist-get 'role s))))
                          (maduin--config-get 'seats section))))

(defun maduin--seat-model (seat)
  "Return model configured for SEAT, or \"default\".
Searches concierge/designer/fleet seat sections by name."
  (or (cl-loop for section in '(concierge designer fleet)
               for seats = (maduin--config-get 'seats section)
               thereis (and (listp seats)
                            (alist-get 'model
                                       (cl-find-if
                                        (lambda (s) (string= (alist-get 'name s) seat))
                                        seats))))
      "default"))

(defun maduin--seat-workdir (seat)
  "Return workspace directory for SEAT under workspaces.path.
Resolved under the current project root."
  (expand-file-name
   seat
   (expand-file-name
    (or (maduin--config-get 'path 'workspaces)
        "harness/workspaces")
    (maduin-project-root))))

;;; Commands

;;;###autoload
(defun maduin-start ()
  "Start all agents per config and open the cockpit.
For each seat: spawn an agent.  For each implementer seat: spawn an
agent and start its pipeline polling.  Then show and refresh the
cockpit dashboard."
  (interactive)
  (dolist (pair (maduin--seats))
    (let* ((seat (car pair))
           (role (cdr pair))
           (model (maduin--seat-model seat))
           (workdir (maduin--seat-workdir seat)))
      (make-directory workdir t)
      (maduin-agent-spawn seat role model workdir)
      (when (string= role "implementer")
        (maduin-pipeline-start-fleet seat))))
  (maduin-cockpit-show)
  (maduin-cockpit-refresh)
  (message "maduin started"))

;;;###autoload
(defun maduin-stop ()
  "Gracefully stop all agents and kill any remaining sessions.
Requests handoff from each agent, waits up to welfare.handoff-timeout,
then kills survivors.  Logs shutdown."
  (interactive)
  (let ((inhibit-redisplay t)
        (debug-on-error nil)
        (saved-modelines nil))
    ;; Nuke mode-line-format on every visible buffer to prevent
    ;; doom-modeline :eval segments from firing during buffer kills.
    ;; let-binding mode-line-format doesn't override buffer-local values.
    (dolist (buf (buffer-list))
      (when (buffer-live-p buf)
        (push (cons buf (buffer-local-value 'mode-line-format buf)) saved-modelines)
        (with-current-buffer buf
          (setq mode-line-format nil))))
    (unwind-protect
        (condition-case err
            (progn
              (maduin-handoff-stop-all
               (maduin--config-get 'handoff-timeout 'welfare))
              ;; Land implementer branches when configured; never abort stop.
              (when (maduin--config-get 'land-on-stop 'workspaces)
                (dolist (pair (maduin--seats))
                  (when (string= (cdr pair) "implementer")
                    (condition-case err
                        (maduin-pipeline-land-branch (car pair))
                      (error
                       (message "maduin: land-branch failed for %s: %s"
                                (car pair) (error-message-string err)))))))
              (dolist (pair (maduin-session-list))
                (maduin-session-kill (car pair)))
              ;; Stop resolver (beadle) sessions; never abort stop.
              (dolist (seat (mapcar #'car
                                    (copy-sequence
                                     maduin-resolver-processes)))
                (condition-case err
                    (maduin-resolver-stop seat)
                  (error
                   (message "maduin: resolver stop failed for %s: %s"
                            seat (error-message-string err))))))
          (error
           (message "maduin: shutdown error (continuing): %s"
                    (error-message-string err))))
      ;; Restore modelines on surviving buffers.
      (dolist (pair saved-modelines)
        (let ((buf (car pair)))
          (when (buffer-live-p buf)
            (with-current-buffer buf
              (setq mode-line-format (cdr pair))))))))
  (message "maduin stopped"))

;;;###autoload
(defun maduin-status ()
  "Refresh cockpit and show a summary message."
  (interactive)
  (maduin-cockpit-refresh)
  (message "maduin: %d sessions | %s"
           (length (maduin-session-list))
           (maduin-cockpit--pipeline-summary)))

;;;###autoload
(defun maduin-restart ()
  "Stop then start all agents."
  (interactive)
  (maduin-stop)
  (maduin-start))

;;;###autoload
(defun maduin-attach (seat)
  "Attach to SEAT's session buffer.
SEAT is chosen by completing-read from configured seats."
  (interactive
   (list (completing-read "Attach to seat: "
                          (mapcar #'car (maduin--seats))
                          nil t)))
  (maduin-session-switch seat))

;;;###autoload
(defun maduin-bootstrap ()
  "First-time setup: create dirs and verify bd init.
Creates .agents/brain, .agents/handoff, .agents/logs and per-seat
workspace dirs.  Hints to run `bd init' when .beads is absent."
  (interactive)
  (dolist (dir '(".agents/brain" ".agents/handoff" ".agents/logs"))
    (make-directory dir t))
  (dolist (pair (maduin--seats))
    (make-directory (maduin--seat-workdir (car pair)) t))
  ;; Ensure per-seat git worktrees; never abort on failure (logged, nil).
  (dolist (pair (maduin--seats))
    (condition-case err
        (maduin-workspace-ensure (car pair))
      (error
       (message "maduin: worktree ensure failed for %s: %s"
                (car pair) (error-message-string err)))))
  (if (file-exists-p ".beads")
      (message "maduin: bootstrap done")
    (message "maduin: bootstrap done; hint: run `bd init` (no .beads found)")))

;;; Shutdown hook

(add-hook 'kill-emacs-hook #'maduin-stop)

;;; Dev reload — edit-then-reload loop for developing the harness itself.

(defvar maduin--feature-list
  '(maduin-cockpit maduin-terminal maduin-concierge maduin-pipeline maduin-handoff
    maduin-agent maduin-session maduin-brain
    maduin-bd-bridge maduin-config)
  "Features to unload/reload in dependency order (leaf-first).")

;;;###autoload
(defun maduin-reload ()
  "Unload and reload all maduin modules.
Development loop: edit a .el file, run this, keep the new code.
Gracefully stops agents first, preserving handoff caches."
  (interactive)
  (when (or (not (called-interactively-p 'interactive))
            (y-or-n-p "Stop running agents and reload maduin? "))
    (maduin-stop)
    (dolist (feat maduin--feature-list)
      (unload-feature feat 'force))
    (let ((dir (file-name-directory (locate-library "maduin"))))
      (when dir (add-to-list 'load-path dir)))
    (dolist (feat (cons 'maduin maduin--feature-list))
      (require feat nil 'noerror))
    (maduin-mode 1)
    (message "maduin reloaded")))

(provide 'maduin)

;;; maduin.el ends here
