;;; maduin-session.el --- buffer and process manager  -*- lexical-binding: t; -*-

;;; Commentary:

;; Each agent seat lives in one Emacs buffer backed by an opencode
;; subprocess.  Buffers replace tmux sessions; Emacs IS the terminal
;; multiplexer.

;;; Code:

(require 'cl-lib)

(condition-case nil
    (require 'maduin-logging)
  (error nil))

(defvar maduin-opencode-command "opencode"
  "Executable name of the opencode CLI.")

(defvar maduin-session-on-exit-hook nil
  "Hooks run when an agent process exits.")

;; Buffer-local session state.
(defvar maduin-seat nil)
(defvar maduin-role nil)
(defvar maduin-model nil)
(defvar maduin-status nil)
(defvar maduin-started-at nil)
(defvar maduin-current-task nil)
(defvar maduin-intent nil
  "Intended opencode command (list) when no process could be spawned.")
(defvar maduin-workdir nil)

(defun maduin-session--buffer-name (role seat)
  "Buffer name for ROLE seat SEAT."
  (format "*maduin/%s-%s*" role seat))

(defun maduin-session--buffer (seat-name)
  "Find agent buffer whose `maduin-seat' is SEAT-NAME."
  (cl-find-if
   (lambda (buf)
     (and (buffer-live-p buf)
          (local-variable-p 'maduin-seat buf)
          (string= (buffer-local-value 'maduin-seat buf) seat-name)))
   (buffer-list)))

(defun maduin-session--sentinel (proc event)
  "Sentinel for agent process PROC.  EVENT is the exit string."
  (let ((buf (process-buffer proc)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq maduin-status 'dead)
        (setq maduin-current-task nil)
        (message "maduin: session %s exited (%s)"
                 maduin-seat event))
      (run-hooks 'maduin-session-on-exit-hook))))

(defun maduin-session-create (seat-name role model workdir)
  "Create session buffer for SEAT-NAME with ROLE and MODEL in WORKDIR.

Return the buffer.  Launches opencode as subprocess when the CLI is
available; otherwise still returns a buffer holding the spawn intent
in `maduin-intent' with status `dead'."
  (let* ((buf (get-buffer-create (maduin-session--buffer-name role seat-name)))
         (exe (executable-find maduin-opencode-command)))
    (with-current-buffer buf
      (when (fboundp 'compilation-mode)
        (compilation-mode))
      (setq-local maduin-seat seat-name)
      (setq-local maduin-role role)
      (setq-local maduin-model model)
      (setq-local maduin-status 'running)
      (setq-local maduin-started-at (float-time))
      (setq-local maduin-current-task nil)
      (setq-local maduin-workdir workdir)
      (setq-local maduin-intent (list maduin-opencode-command "--model" model))
      (if exe
          (progn
            (make-process
             :name (format "maduin-%s-%s" role seat-name)
             :buffer buf
             :command (list exe "--model" model)
             :sentinel #'maduin-session--sentinel)
            (set-process-query-on-exit-flag (get-buffer-process buf) nil))
        (setq maduin-status 'dead)
        (message "maduin: opencode not found; session %s created without process"
                 seat-name)))
    buf))

(defun maduin-session-kill (seat-name)
  "Kill process and buffer for SEAT-NAME.  Return non-nil if anything was killed."
  (let* ((buf (maduin-session--buffer seat-name))
         (proc (and buf (get-buffer-process buf)))
         (had (or (and proc (process-live-p proc))
                  (and buf (buffer-live-p buf)))))
    (when (and proc (process-live-p proc))
      (ignore-errors (kill-process proc)))
    (when (and buf (buffer-live-p buf))
      (ignore-errors (kill-buffer buf)))
    (and had t)))

(defun maduin-session-list ()
  "Return alist ((SEAT-NAME . STATUS) ...) of all agent sessions."
  (cl-loop for buf in (buffer-list)
           when (and (buffer-live-p buf)
                     (local-variable-p 'maduin-seat buf))
           collect (cons (buffer-local-value 'maduin-seat buf)
                         (buffer-local-value 'maduin-status buf))))

(defun maduin-session-switch (seat-name)
  "Switch to buffer of SEAT-NAME.  Signal error if missing."
  (let ((buf (maduin-session--buffer seat-name)))
    (unless buf
      (error "maduin: no session for seat %s" seat-name))
    (switch-to-buffer buf)))

(defun maduin-session-alive-p (seat-name)
  "Return t when SEAT-NAME has a live process and status not `dead'."
  (let* ((buf (maduin-session--buffer seat-name))
         (proc (and buf (get-buffer-process buf)))
         (status (and buf (buffer-local-value 'maduin-status buf))))
    (and proc (process-live-p proc) (not (eq status 'dead)))))

(provide 'maduin-session)

;;; maduin-session.el ends here
