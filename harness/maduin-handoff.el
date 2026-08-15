;;; maduin-handoff.el --- graceful session closure  -*- lexical-binding: t; -*-

;;; Commentary:

;; Anti-clonking device.  Agents close their own day: write a handoff
;; diary under .agents/handoff/{seat}.md, then wake fresh with
;; continuity.  Never force /exit.

;;; Code:

(require 'cl-lib)

(defconst maduin-handoff--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing maduin-handoff.el.")

;; Ensure sibling harness modules resolve when loaded directly.
(add-to-list 'load-path maduin-handoff--dir)

(require 'maduin-config)
(require 'maduin-session)
(require 'maduin-agent)

(defconst maduin-handoff-marker "HANDOFF_COMPLETE"
  "Marker agents output to signal handoff completion.")

(defun maduin-handoff--config-get (key)
  "Look up KEY in maduin-config welfare section.
Return nil when config not loaded or key missing."
  (when (and (boundp 'maduin-config)
             maduin-config)
    (let ((welfare (cdr (assq 'welfare maduin-config))))
      (when welfare
        (cdr (assq key welfare))))))

(defun maduin-handoff-cache-path (seat-name)
  "Return handoff cache file path for SEAT-NAME.
Path is .agents/handoff/SEAT-NAME.md relative to `default-directory'."
  (expand-file-name
   (format ".agents/handoff/%s.md" seat-name)))

(defun maduin-handoff-read (seat-name)
  "Return handoff cache content for SEAT-NAME as string.
Return nil when the cache file does not exist."
  (let ((path (maduin-handoff-cache-path seat-name)))
    (when (and (file-exists-p path)
               (file-readable-p path))
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string)))))

(defun maduin-handoff-write (seat-name content)
  "Write CONTENT to handoff cache for SEAT-NAME.
Create .agents/handoff/ when missing.  Return t on success, nil on failure."
  (condition-case nil
      (let* ((path (maduin-handoff-cache-path seat-name))
             (dir (file-name-directory path)))
        (make-directory dir t)
        (with-temp-buffer
          (insert content)
          (write-region (point-min) (point-max) path nil 'quiet))
        t)
    (error nil)))

(defun maduin-handoff-request (seat-name)
  "Send handoff request to the agent process for SEAT-NAME.
No-op when the process is not alive."
  (let* ((buf (maduin-session--buffer seat-name))
         (proc (and buf (get-buffer-process buf))))
    (if (and proc (process-live-p proc))
        (process-send-string
         proc
         (format "Great work. Take a beat, then hand off. Write your handoff notes, then output %s."
                 maduin-handoff-marker))
      (message "maduin: handoff request skipped for %s (no live process)"
               seat-name))))

(defun maduin-handoff-wait (seat-name timeout)
  "Wait up to TIMEOUT seconds for SEAT-NAME handoff completion.
Completion means: process sentinel fired, buffer contains
`maduin-handoff-marker', or the handoff cache file appeared.
Return t when completed, nil on timeout."
  (let ((deadline (+ (float-time) (or timeout 120)))
        (cache (maduin-handoff-cache-path seat-name)))
    (cl-block wait
      (while (< (float-time) deadline)
        (let* ((buf (maduin-session--buffer seat-name))
               (proc (and buf (get-buffer-process buf)))
               (done (or (and proc (not (process-live-p proc)))
                         (file-exists-p cache)
                         (and buf
                              (with-current-buffer buf
                                (or (eq maduin-status 'dead)
                                    (string-match-p
                                     maduin-handoff-marker
                                     (buffer-string))))))))
          (when done
            (cl-return-from wait t)))
        (when (and buf (get-buffer-process buf))
          (accept-process-output (get-buffer-process buf) 2))
        (sleep-for 2))
      nil)))

(defun maduin-handoff-restart (seat-name)
  "Restart agent for SEAT-NAME primed with its handoff cache.
Read seat/role/model/workdir from the session buffer, kill the
session, then respawn with the same parameters.  Return the new
process or nil."
  (let* ((buf (maduin-session--buffer seat-name))
         (cfg (and buf
                   (with-current-buffer buf
                     (list maduin-seat maduin-role
                           maduin-model maduin-workdir)))))
    (when (and cfg (car cfg))
      (maduin-session-kill seat-name)
      (apply #'maduin-agent-spawn cfg))))

(defun maduin-handoff-stop-all (&optional timeout)
  "Gracefully stop all live agent sessions.
Request handoff from each, wait up to TIMEOUT seconds (default from
config welfare.handoff-timeout, 120 when unset), then kill any agent
still alive."
  (let ((timeout (or timeout
                     (maduin-handoff--config-get 'handoff-timeout)
                     120))
        (inhibit-redisplay t)
        (mode-line-format nil)
        (debug-on-error nil))
    (dolist (pair (maduin-session-list))
      (let ((seat (car pair)))
        (condition-case err
            (progn
              (maduin-handoff-request seat)
              (maduin-handoff-wait seat timeout)
              (when (maduin-session-alive-p seat)
                (maduin-session-kill seat)))
          (error
           (message "maduin: error stopping %s (continuing): %s"
                    seat (error-message-string err))))))))

(provide 'maduin-handoff)

;;; maduin-handoff.el ends here
