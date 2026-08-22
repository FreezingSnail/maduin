;;; maduin-logging.el --- runtime logging  -*- lexical-binding: t; -*-

;;; Commentary:

;; One append-only buffer (`*maduin-log*') recording what the harness is
;; doing: task pickup, session completion, land/merge outcome, close, the
;; review gate and its verdict, recovery, and every warning or error a
;; module used to drop into `message'.
;;
;; `maduin-log' is the single entry point.  Modules call it through an
;; fboundp guard (`maduin-bd--log-error', `maduin-workspace--log-warning',
;; `maduin-session--log'), so loading this file activates logging in code
;; that already reports through those helpers.
;;
;; Two hard rules, because the callers are process filters, sentinels and
;; timers:
;;
;;   1. Logging never signals.  A broken log line must not abort a land, a
;;      close, or a review verdict.
;;   2. Logging never moves point in a window a human is reading.  The log
;;      buffer follows its tail only while point sits at the end.

;;; Code:

(require 'cl-lib)

;; evil (optional) — bindings must be evil-aware (AGENTS.md).  Declared so
;; this file byte-compiles when evil is not installed.
(declare-function evil-define-key* "evil-core" (state keymap &rest bindings))

(defconst maduin-log-buffer-name "*maduin-log*"
  "Name of the append-only maduin log buffer.")

(defconst maduin-log--levels '((debug . 0) (info . 1) (warn . 2) (error . 3))
  "Ordered log levels mapped to their numeric severity.")

(defvar maduin-log-level 'info
  "Minimum severity recorded in the log buffer.
One of `debug', `info', `warn', or `error'.  `debug' adds the run-loop's
per-tick polling detail.")

(defvar maduin-log-max-lines 5000
  "Maximum lines retained in the log buffer; older lines are dropped.
A nil or non-positive value disables trimming.")

(defvar maduin-log-echo-level 'error
  "Minimum severity also echoed through `message', or nil to echo nothing.
Errors stay visible without the log buffer on screen.")

(defvar maduin-log-time-format "%H:%M:%S"
  "`format-time-string' format for a log line's timestamp.")

(defface maduin-log-timestamp '((t :inherit shadow))
  "Face for log line timestamps."
  :group 'maduin)

(defface maduin-log-debug '((t :inherit shadow))
  "Face for `debug' level tags."
  :group 'maduin)

(defface maduin-log-info '((t :inherit success))
  "Face for `info' level tags."
  :group 'maduin)

(defface maduin-log-warn '((t :inherit warning))
  "Face for `warn' level tags."
  :group 'maduin)

(defface maduin-log-error '((t :inherit error))
  "Face for `error' level tags."
  :group 'maduin)

;;; Pure helpers

(defun maduin-log--severity (level)
  "Return numeric severity of LEVEL, or nil when LEVEL is unknown."
  (cdr (assq level maduin-log--levels)))

(defun maduin-log-enabled-p (level &optional threshold)
  "Return non-nil when LEVEL is at or above THRESHOLD.
THRESHOLD defaults to `maduin-log-level'.  An unknown LEVEL is treated as
`info' so a typo still records instead of vanishing."
  (let ((severity (or (maduin-log--severity level)
                      (maduin-log--severity 'info)))
        (floor (or (maduin-log--severity (or threshold maduin-log-level))
                   (maduin-log--severity 'info))))
    (>= severity floor)))

(defun maduin-log--level-face (level)
  "Return the face used for LEVEL's tag."
  (pcase level
    ('debug 'maduin-log-debug)
    ('warn 'maduin-log-warn)
    ('error 'maduin-log-error)
    (_ 'maduin-log-info)))

(defun maduin-log--tag (level)
  "Return LEVEL's fixed-width display tag."
  (format "%-5s" (if (symbolp level) (symbol-name level) level)))

(defun maduin-log--message (format-string args)
  "Return FORMAT-STRING applied to ARGS as one line, never signalling.
With no ARGS, FORMAT-STRING is used verbatim: existing callers pass
pre-built text that may legitimately contain `%'."
  (let ((text (condition-case nil
                  (cond
                   ((null args) (if (stringp format-string)
                                    format-string
                                  (format "%S" format-string)))
                   (t (apply #'format format-string args)))
                (error (format "%S %S" format-string args)))))
    (replace-regexp-in-string "[\r\n]+" " " (string-trim text))))

(defun maduin-log--line (level format-string args &optional time)
  "Return the rendered log line for LEVEL, FORMAT-STRING, ARGS, and TIME."
  (concat (propertize (format-time-string maduin-log-time-format time)
                      'face 'maduin-log-timestamp)
          " "
          (propertize (maduin-log--tag level)
                      'face (maduin-log--level-face level))
          " "
          (maduin-log--message format-string args)))

(defun maduin-log--pair (key value)
  "Return KEY=VALUE rendered for a structured event line."
  (format "%s=%s"
          (if (keywordp key) (substring (symbol-name key) 1) key)
          (cond ((null value) "-")
                ((stringp value) (if (string-empty-p value) "-" value))
                (t (format "%s" value)))))

(defun maduin-log-event-string (event plist)
  "Return EVENT and PLIST rendered as `event key=value ...'."
  (let ((pairs nil)
        (rest plist))
    (while (cdr rest)
      (push (maduin-log--pair (car rest) (cadr rest)) pairs)
      (setq rest (cddr rest)))
    (mapconcat #'identity (cons (format "%s" event) (nreverse pairs)) " ")))

;;; Buffer

(defvar maduin-log-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    map)
  "Keymap for `maduin-log-mode'.")

(defconst maduin-log--bindings
  '(("q" . quit-window)
    ("c" . maduin-log-clear)
    ("l" . maduin-log-set-level)
    ("G" . maduin-log-end))
  "Log buffer keybindings as ((KEY . DEF) ...), KEY a `kbd' string.
Single source of truth; mirrored into evil normal/motion states.")

(defun maduin-log--bind (key def)
  "Bind KEY (a `kbd' string) to DEF in the log map and evil states.
Evil-aware by construction (AGENTS.md): the plain keymap and the evil
normal/motion states are bound from one place."
  (define-key maduin-log-mode-map (kbd key) def)
  (when (and (featurep 'evil) (fboundp 'evil-define-key*))
    (evil-define-key* 'normal maduin-log-mode-map (kbd key) def)
    (evil-define-key* 'motion maduin-log-mode-map (kbd key) def)))

(defun maduin-log--evil-setup ()
  "Mirror log bindings into evil normal/motion states.  No-op without evil."
  (when (and (featurep 'evil) (fboundp 'evil-define-key*))
    (dolist (binding maduin-log--bindings)
      (maduin-log--bind (car binding) (cdr binding)))))

(dolist (binding maduin-log--bindings)
  (maduin-log--bind (car binding) (cdr binding)))

(define-derived-mode maduin-log-mode special-mode "Maduin-Log"
  "Major mode for the append-only maduin log buffer."
  (setq-local truncate-lines nil)
  (setq-local buffer-read-only t)
  (maduin-log--evil-setup))

(defun maduin-log--buffer ()
  "Return the live log buffer, creating and initializing it when absent."
  (or (get-buffer maduin-log-buffer-name)
      (with-current-buffer (get-buffer-create maduin-log-buffer-name)
        (maduin-log-mode)
        (current-buffer))))

(defun maduin-log--trim ()
  "Drop the oldest lines beyond `maduin-log-max-lines' in the current buffer."
  (when (and (integerp maduin-log-max-lines) (> maduin-log-max-lines 0))
    (let ((excess (- (count-lines (point-min) (point-max))
                     maduin-log-max-lines)))
      (when (> excess 0)
        (save-excursion
          (goto-char (point-min))
          (forward-line excess)
          (delete-region (point-min) (point)))))))

(defun maduin-log--insert (line)
  "Append LINE to the log buffer, following the tail only when at it."
  (with-current-buffer (maduin-log--buffer)
    (let* ((inhibit-read-only t)
           (at-tail (= (point) (point-max))))
      (save-excursion
        (goto-char (point-max))
        (unless (or (bobp) (bolp)) (insert "\n"))
        (insert line "\n")
        (maduin-log--trim))
      (when at-tail
        (goto-char (point-max))
        (dolist (window (get-buffer-window-list (current-buffer) nil t))
          (set-window-point window (point-max)))))))

;;; Public API

(defun maduin-log (level format-string &rest args)
  "Record FORMAT-STRING with ARGS at LEVEL in the maduin log buffer.
LEVEL is `debug', `info', `warn', or `error'.  With no ARGS,
FORMAT-STRING is recorded verbatim.  Return the recorded line, or nil
when LEVEL is below `maduin-log-level'.  Never signals: a logging failure
must not abort the land, close, or verdict that produced it."
  (condition-case nil
      (when (maduin-log-enabled-p level)
        (let ((line (maduin-log--line level format-string args)))
          (maduin-log--insert line)
          (when (and maduin-log-echo-level
                     (maduin-log-enabled-p level maduin-log-echo-level))
            (message "maduin: %s" (maduin-log--message format-string args)))
          line))
    (error nil)))

(defun maduin-log-event (level event &rest plist)
  "Record structured EVENT with PLIST fields at LEVEL.
Renders as `event key=value ...' with nil values shown as `-', so the log
stays greppable (e.g. `land task=maduin-7 result=conflict')."
  (condition-case nil
      (maduin-log level (maduin-log-event-string event plist))
    (error nil)))

;;;###autoload
(defun maduin-log-show ()
  "Display the maduin log buffer without selecting it."
  (interactive)
  (display-buffer (maduin-log--buffer)))

(defun maduin-log-clear ()
  "Erase the log buffer's contents."
  (interactive)
  (with-current-buffer (maduin-log--buffer)
    (let ((inhibit-read-only t))
      (erase-buffer))))

(defun maduin-log-end ()
  "Move point to the end of the log buffer (resume tailing)."
  (interactive)
  (goto-char (point-max)))

(defun maduin-log-set-level (level)
  "Set `maduin-log-level' to LEVEL for this session."
  (interactive
   (list (intern (completing-read
                  "Log level: "
                  (mapcar (lambda (entry) (symbol-name (car entry)))
                          maduin-log--levels)
                  nil t nil nil (symbol-name maduin-log-level)))))
  (unless (maduin-log--severity level)
    (user-error "maduin: unknown log level %S" level))
  (setq maduin-log-level level)
  (maduin-log 'info "log level set to %s" level)
  level)

(provide 'maduin-logging)

;;; maduin-logging.el ends here
