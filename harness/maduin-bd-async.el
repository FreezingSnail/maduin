;;; maduin-bd-async.el --- Non-blocking bd CLI calls -*- lexical-binding: t; -*-

;;; Commentary:

;; Async bd subprocess substrate.  Consumers supply argv elements and receive
;; completion callbacks without blocking Emacs input.  Identical in-flight
;; commands share one process and fan its result out to every callback.

;;; Code:

(require 'cl-lib)
(require 'maduin-bd-bridge)

(defvar maduin-bd-async--program "bd"
  "Executable used by `maduin-bd-async-call'.
Tests may bind this to a known fast executable without requiring bd.")

(defvar maduin-bd-async--inflight (make-hash-table :test #'equal)
  "Map bd argv keys to (PROCESS . CALLBACKS).
CALLBACKS receive EXIT-CODE and STDOUT after PROCESS exits.")

(defun maduin-bd-async--key (args)
  "Return the single-flight key for bd ARGS."
  (mapconcat #'identity args "\0"))

(defun maduin-bd-async--log-error (message)
  "Log async bd MESSAGE without allowing logging failures to escape."
  (condition-case nil
      (maduin-bd--log-error message)
    (error (message "[maduin-bd-async] ERROR: %s" message))))

(defun maduin-bd-async--kill-buffer (buffer)
  "Kill BUFFER when it remains live."
  (when (buffer-live-p buffer)
    (kill-buffer buffer)))

(defun maduin-bd-async--sentinel (process _event)
  "Complete PROCESS callbacks after it exits, then release its resources."
  (unless (process-live-p process)
    (let* ((key (process-get process 'maduin-bd-async-key))
           (entry (and key (gethash key maduin-bd-async--inflight)))
           (stdout-buffer (process-buffer process))
           (stderr-buffer (process-get process 'maduin-bd-async-stderr-buffer)))
      (unwind-protect
          (when (and entry (eq process (car entry)))
            (let ((exit-code (process-exit-status process))
                  (stdout (if (buffer-live-p stdout-buffer)
                              (with-current-buffer stdout-buffer (buffer-string))
                            ""))
                  (callbacks (cdr entry)))
              (when (/= exit-code 0)
                (maduin-bd-async--log-error
                 (format "bd async %s failed (exit %d)" key exit-code)))
              (unwind-protect
                  (dolist (callback callbacks)
                    (condition-case err
                        (funcall callback exit-code stdout)
                      (error
                       (maduin-bd-async--log-error
                        (format "bd async callback failed for %s: %s"
                                key (error-message-string err))))))
                (remhash key maduin-bd-async--inflight))))
        (maduin-bd-async--kill-buffer stdout-buffer)
        (maduin-bd-async--kill-buffer stderr-buffer)))))

(defun maduin-bd-async-call (args callback)
  "Run bd ARGS asynchronously and call CALLBACK with EXIT-CODE and STDOUT.
ARGS must be a list of strings passed directly to the bd executable.  Return
its in-flight key, or nil when bd is unavailable or the process cannot start.
Overlapping calls with identical ARGS share one process and each callback runs
when that process completes."
  (let ((executable (executable-find maduin-bd-async--program)))
    (cond
     ((not executable)
      (maduin-bd-async--log-error
       (format "bd async executable not found: %s" maduin-bd-async--program))
      nil)
     (t
      (let* ((key (maduin-bd-async--key args))
             (entry (gethash key maduin-bd-async--inflight)))
        (if entry
            (progn
              (setcdr entry (append (cdr entry) (list callback)))
              key)
          (let* ((stdout-buffer (generate-new-buffer " *maduin-bd-async*"))
                 (stderr-buffer (generate-new-buffer " *maduin-bd-async-stderr*"))
                 (process
                  (condition-case err
                      (make-process
                       :name "maduin-bd-async"
                       :buffer stdout-buffer
                       :command (cons executable args)
                       :connection-type 'pipe
                       :stderr stderr-buffer
                       :sentinel #'maduin-bd-async--sentinel
                       :noquery t)
                    (error
                     (maduin-bd-async--log-error
                      (format "bd async failed to spawn: %s"
                              (error-message-string err)))
                     nil))))
            (if process
                (progn
                  (process-put process 'maduin-bd-async-key key)
                  (process-put process 'maduin-bd-async-stderr-buffer stderr-buffer)
                  (puthash key (cons process (list callback))
                           maduin-bd-async--inflight)
                  key)
              (maduin-bd-async--kill-buffer stdout-buffer)
              (maduin-bd-async--kill-buffer stderr-buffer)
              nil))))))))

(defun maduin-bd-async-json (args callback)
  "Run bd ARGS asynchronously and call CALLBACK with DATA and EXIT-CODE.
DATA is STDOUT decoded by `maduin-bd--json-data', or nil when it is not a
JSON array.  Return the in-flight key, or nil on unavailable/spawn failure."
  (maduin-bd-async-call
   args
   (lambda (exit-code stdout)
     (funcall callback (maduin-bd--json-data stdout) exit-code))))

(defun maduin-bd-async-cancel-all ()
  "Delete every live async bd process and clear the in-flight registry."
  (let (processes)
    (maphash (lambda (_key entry) (push (car entry) processes))
             maduin-bd-async--inflight)
    ;; Clear first so deletion sentinels cannot invoke cancelled callbacks.
    (clrhash maduin-bd-async--inflight)
    (dolist (process processes)
      (when (process-live-p process)
        (delete-process process)))))

(provide 'maduin-bd-async)

;;; maduin-bd-async.el ends here
