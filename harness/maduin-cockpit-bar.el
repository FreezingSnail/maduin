;;; maduin-cockpit-bar.el --- cockpit keybinding reference bar -*- lexical-binding: t; -*-

;;; Commentary:

;; Persistent mode-line keybinding reference for cockpit buffers.

;;; Code:

(require 'maduin-cockpit-face)

(defvar maduin-cockpit--bindings nil
  "Forward declaration of cockpit keybinding pairs.")

(defvar-local maduin-cockpit-bar--map nil
  "Keymap used to filter candidate cockpit hints.")

(defvar-local maduin-cockpit-bar--specs nil
  "Candidate hints as an alist of (KEY-STRING . LABEL).")

(defvar-local maduin-cockpit-bar--extra nil
  "Hints always shown as an alist of (KEY-STRING . LABEL).")

(defvar-local maduin-cockpit-bar--rendered nil
  "Cached rendered bar string read by the mode line.")

(defvar-local maduin-cockpit-bar--installed nil
  "Non-nil when the bar element is installed in this buffer.")

(defconst maduin-cockpit-bar--labels
  '((maduin-cockpit-refresh . "refresh")
    (quit-window . "quit")
    (maduin-cockpit-inbox . "inbox")
    (maduin-cockpit--toggle-backend . "backend")
    (maduin-cockpit-config . "config")
    (maduin-log-show . "log")
    (maduin-concierge . "concierge")
    (maduin-concierge-dismiss . "dismiss")
    (maduin-designer-drop-in . "design drop-in")
    (maduin-designer-pending-tasks . "pending"))
  "Command-to-label map for cockpit keybinding hints.")

(defun maduin-cockpit-bar--label (command)
  "Return the display label for COMMAND.
Unknown cockpit commands use their symbol name without the cockpit prefix."
  (or (alist-get command maduin-cockpit-bar--labels)
      (replace-regexp-in-string "\\`maduin-cockpit-+" ""
                                (symbol-name command))))

(defun maduin-cockpit-bar--specs-from-bindings ()
  "Return bar specs derived from `maduin-cockpit--bindings'."
  (mapcar (lambda (binding)
            (cons (car binding) (maduin-cockpit-bar--label (cdr binding))))
          maduin-cockpit--bindings))

(defun maduin-cockpit-bar--bound ()
  "Return specs whose keys resolve in `maduin-cockpit-bar--map'."
  (delq nil
        (mapcar (lambda (spec)
                  (when (and maduin-cockpit-bar--map
                             (lookup-key maduin-cockpit-bar--map
                                         (kbd (car spec))))
                    spec))
                maduin-cockpit-bar--specs)))

(defun maduin-cockpit-bar--entries ()
  "Return bound specs followed by entries always shown."
  (append (maduin-cockpit-bar--bound) maduin-cockpit-bar--extra))

(defun maduin-cockpit-bar--render ()
  "Return cached-mode-line-ready hint text for the current buffer."
  (let ((entries (maduin-cockpit-bar--entries)))
    (if entries
        (mapconcat (lambda (entry)
                     (propertize (format "[%s] %s" (car entry) (cdr entry))
                                 'face 'maduin-cockpit-bar))
                   entries " ")
      "")))

(defun maduin-cockpit-bar-install ()
  "Render then prepend the cockpit hint bar to this buffer's mode line.
The installed `:eval' form only reads `maduin-cockpit-bar--rendered'.
Never signal when the buffer has no usable keymap or mode line."
  (condition-case nil
      (progn
        (setq-local maduin-cockpit-bar--map maduin-cockpit-map)
        (setq-local maduin-cockpit-bar--specs
                    (maduin-cockpit-bar--specs-from-bindings))
        (setq-local maduin-cockpit-bar--rendered (maduin-cockpit-bar--render))
        (unless maduin-cockpit-bar--installed
          (when (and maduin-cockpit-bar--map (consp mode-line-format))
            (let ((bar '((:eval maduin-cockpit-bar--rendered))))
              (setq-local mode-line-format
                          (if (equal (car mode-line-format) "%e")
                              (cons "%e" (append bar (cdr mode-line-format)))
                            (append bar mode-line-format)))
              (setq-local maduin-cockpit-bar--installed t)))))
    (error nil)))

(provide 'maduin-cockpit-bar)

;;; maduin-cockpit-bar.el ends here
