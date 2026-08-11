;;; super-harness-session.el --- buffer and process manager  -*- lexical-binding: t; -*-

;;; Commentary:

;; Each agent seat lives in one Emacs buffer backed by an opencode
;; subprocess.  Buffers replace tmux sessions; Emacs IS the terminal
;; multiplexer.

;;; Code:

(require 'cl-lib)

(condition-case nil
    (require 'super-harness-logging)
  (error nil))

(defvar super-harness-opencode-command "opencode"
  "Executable name of the opencode CLI.")

(defvar super-harness-session-on-exit-hook nil
  "Hooks run when an agent process exits.")

;; Buffer-local session state.
(defvar super-harness-seat nil)
(defvar super-harness-role nil)
(defvar super-harness-model nil)
(defvar super-harness-status nil)
(defvar super-harness-started-at nil)
(defvar super-harness-current-task nil)
(defvar super-harness-intent nil
  "Intended opencode command (list) when no process could be spawned.")
(defvar super-harness-workdir nil)

(defun super-harness-session--buffer-name (role seat)
  "Buffer name for ROLE seat SEAT."
  (format "*super-harness/%s-%s*" role seat))

(defun super-harness-session--buffer (seat-name)
  "Find agent buffer whose `super-harness-seat' is SEAT-NAME."
  (cl-find-if
   (lambda (buf)
     (and (buffer-live-p buf)
          (local-variable-p 'super-harness-seat buf)
          (string= (buffer-local-value 'super-harness-seat buf) seat-name)))
   (buffer-list)))

(defun super-harness-session--sentinel (proc event)
  "Sentinel for agent process PROC.  EVENT is the exit string."
  (let ((buf (process-buffer proc)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq super-harness-status 'dead)
        (setq super-harness-current-task nil)
        (message "super-harness: session %s exited (%s)"
                 super-harness-seat event))
      (run-hooks 'super-harness-session-on-exit-hook))))

(defun super-harness-session-create (seat-name role model workdir)
  "Create session buffer for SEAT-NAME with ROLE and MODEL in WORKDIR.

Return the buffer.  Launches opencode as subprocess when the CLI is
available; otherwise still returns a buffer holding the spawn intent
in `super-harness-intent' with status `dead'."
  (let* ((buf (get-buffer-create (super-harness-session--buffer-name role seat-name)))
         (exe (executable-find super-harness-opencode-command)))
    (with-current-buffer buf
      (when (fboundp 'compilation-mode)
        (compilation-mode))
      (setq-local super-harness-seat seat-name)
      (setq-local super-harness-role role)
      (setq-local super-harness-model model)
      (setq-local super-harness-status 'running)
      (setq-local super-harness-started-at (float-time))
      (setq-local super-harness-current-task nil)
      (setq-local super-harness-workdir workdir)
      (setq-local super-harness-intent (list super-harness-opencode-command "--model" model))
      (if exe
          (progn
            (make-process
             :name (format "super-harness-%s-%s" role seat-name)
             :buffer buf
             :command (list exe "--model" model)
             :sentinel #'super-harness-session--sentinel)
            (set-process-query-on-exit-flag (get-buffer-process buf) nil))
        (setq super-harness-status 'dead)
        (message "super-harness: opencode not found; session %s created without process"
                 seat-name)))
    buf))

(defun super-harness-session-kill (seat-name)
  "Kill process and buffer for SEAT-NAME.  Return non-nil if anything was killed."
  (let* ((buf (super-harness-session--buffer seat-name))
         (proc (and buf (get-buffer-process buf)))
         (had (or (and proc (process-live-p proc))
                  (and buf (buffer-live-p buf)))))
    (when (and proc (process-live-p proc))
      (kill-process proc))
    (when (and buf (buffer-live-p buf))
      (kill-buffer buf))
    (and had t)))

(defun super-harness-session-list ()
  "Return alist ((SEAT-NAME . STATUS) ...) of all agent sessions."
  (cl-loop for buf in (buffer-list)
           when (and (buffer-live-p buf)
                     (local-variable-p 'super-harness-seat buf))
           collect (cons (buffer-local-value 'super-harness-seat buf)
                         (buffer-local-value 'super-harness-status buf))))

(defun super-harness-session-switch (seat-name)
  "Switch to buffer of SEAT-NAME.  Signal error if missing."
  (let ((buf (super-harness-session--buffer seat-name)))
    (unless buf
      (error "super-harness: no session for seat %s" seat-name))
    (switch-to-buffer buf)))

(defun super-harness-session-alive-p (seat-name)
  "Return t when SEAT-NAME has a live process and status not `dead'."
  (let* ((buf (super-harness-session--buffer seat-name))
         (proc (and buf (get-buffer-process buf)))
         (status (and buf (buffer-local-value 'super-harness-status buf))))
    (and proc (process-live-p proc) (not (eq status 'dead)))))

(provide 'super-harness-session)

;;; super-harness-session.el ends here
