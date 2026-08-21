;;; maduin-backend.el --- backend adapter registry  -*- lexical-binding: t; -*-

;;; Commentary:

;; Backend adapters register themselves here when loaded.  This module owns
;; only validation, resolution, and dispatch; adapters own CLI behavior.

;;; Code:

(require 'maduin-config)

(defvar maduin-backend-registry (make-hash-table :test #'eq)
  "Map backend symbols to adapter plists.
Each adapter supplies :run-fn, :tui-fn, :complete-p-fn, :diff-fn,
:delete-fn, and :executable.")

(defun maduin-backend--log (fmt &rest args)
  "Log backend FMT with ARGS."
  (message "maduin-backend: %s" (apply #'format fmt args)))

(defun maduin-backend--valid-adapter-p (adapter)
  "Return non-nil when ADAPTER satisfies the backend protocol."
  (condition-case nil
      (and (listp adapter)
           (functionp (plist-get adapter :run-fn))
           (functionp (plist-get adapter :tui-fn))
           (functionp (plist-get adapter :complete-p-fn))
           (functionp (plist-get adapter :diff-fn))
           (functionp (plist-get adapter :delete-fn))
           (stringp (plist-get adapter :executable))
           (not (string-empty-p (plist-get adapter :executable))))
    (error nil)))

(defun maduin-backend-register (backend adapter)
  "Register BACKEND with protocol ADAPTER, returning ADAPTER.
Return nil and log when BACKEND or ADAPTER is malformed."
  (cond
   ((not (symbolp backend))
    (maduin-backend--log "invalid backend name: %S" backend)
    nil)
   ((not (maduin-backend--valid-adapter-p adapter))
    (maduin-backend--log "invalid adapter for %S" backend)
    nil)
   (t
    (puthash backend adapter maduin-backend-registry)
    adapter)))

(defun maduin-backend-get (backend)
  "Return validated adapter registered for BACKEND, or nil and log."
  (cond
   ((not (symbolp backend))
    (maduin-backend--log "invalid backend name: %S" backend)
    nil)
   (t
    (let ((adapter (gethash backend maduin-backend-registry)))
      (cond
       ((not adapter)
        (maduin-backend--log "unknown backend: %S" backend)
        nil)
       ((not (maduin-backend--valid-adapter-p adapter))
        (maduin-backend--log "invalid registered adapter: %S" backend)
        nil)
       (t adapter))))))

(defun maduin-backend-resolve (role seat)
  "Resolve ROLE and SEAT to a registered backend, or nil and log.
`maduin-config-seat-backend' supplies seat-over-role precedence.  Only a nil
config result receives the stable `opencode' default; an explicit unknown
backend never silently changes to another backend."
  (condition-case err
      (let ((backend (maduin-config-seat-backend role seat)))
        (setq backend (or backend 'opencode))
        (if (symbolp backend)
            (and (maduin-backend-get backend) backend)
          (maduin-backend--log "invalid configured backend for %S/%S: %S"
                               role seat backend)
          nil))
    (error
     (maduin-backend--log "cannot resolve backend for %S/%S: %S" role seat err)
     nil)))

(defun maduin-backend--call (backend function-key &rest args)
  "Call BACKEND FUNCTION-KEY with ARGS when its executable is available."
  (let ((adapter (maduin-backend-get backend)))
    (when adapter
      (let ((executable (plist-get adapter :executable)))
        (if (executable-find executable)
            (apply (plist-get adapter function-key) args)
          (maduin-backend--log "backend %S executable unavailable: %s"
                               backend executable)
          nil)))))

(defun maduin-backend-run (backend workdir model agent plan)
  "Run BACKEND in WORKDIR with MODEL, AGENT, and PLAN."
  (maduin-backend--call backend :run-fn workdir model agent plan))

(defun maduin-backend-tui (backend root model prompt &optional agent)
  "Open BACKEND TUI at ROOT with MODEL, PROMPT, and optional AGENT."
  (maduin-backend--call backend :tui-fn root model agent prompt))

(defun maduin-backend-complete-p (backend sid)
  "Return BACKEND completion state for opaque session handle SID."
  (maduin-backend--call backend :complete-p-fn sid))

(defun maduin-backend-diff (backend sid)
  "Return BACKEND diff for opaque session handle SID."
  (maduin-backend--call backend :diff-fn sid))

(defun maduin-backend-delete (backend sid)
  "Delete BACKEND opaque session handle SID."
  (maduin-backend--call backend :delete-fn sid))

(provide 'maduin-backend)

;;; maduin-backend.el ends here
