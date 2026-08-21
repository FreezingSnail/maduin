;;; maduin-cockpit-config.el --- cockpit runtime config panel -*- lexical-binding: t; -*-

;;; Commentary:

;; Runtime-only configuration editing for the cockpit.  `transient' improves
;; discovery when available; the completing-read path is always available.

;;; Code:

(require 'maduin-config)
(require 'transient nil t)

(declare-function maduin-cockpit-refresh "maduin-cockpit" ())
(declare-function transient-setup "transient" (name &optional transient))

(defun maduin-cockpit-config--rows ()
  "Return schema rows grouped by section, preserving schema order.
Each result has the shape (SECTION . ROWS), where ROWS are the plists from
`maduin-config-options'."
  (let (groups)
    (dolist (row (maduin-config-options))
      (let* ((section (plist-get row :section))
             (group (assq section groups)))
        (if group
            (setcdr group (append (cdr group) (list row)))
          (push (cons section (list row)) groups))))
    (nreverse groups)))

(defun maduin-cockpit-config--value-string (value)
  "Return VALUE formatted for a configuration panel description."
  (format "%s" value))

(defun maduin-cockpit-config--display (row)
  "Return the completing-read display string for ROW."
  (format "%s/%s — %s (%s)"
          (plist-get row :section) (plist-get row :key)
          (plist-get row :label)
          (maduin-cockpit-config--value-string (plist-get row :value))))

(defun maduin-cockpit-config--read (row)
  "Read and return a typed value for schema ROW from the minibuffer."
  (let* ((section (plist-get row :section))
         (key (plist-get row :key))
         (label (format "%s/%s" section key))
         (value (plist-get row :value)))
    (pcase (plist-get row :type)
      ('integer (read-number (format "%s: " label) value))
      ('boolean (y-or-n-p (format "%s? " label)))
      ('symbol
       (intern (completing-read
                (format "%s: " label)
                (mapcar #'symbol-name (plist-get row :choices))
                nil t nil nil (and value (symbol-name value)))))
      ('backend
       (let ((choice (completing-read
                      (format "%s: " label)
                      (cons "unset" (mapcar #'symbol-name
                                              (plist-get row :choices)))
                      nil t nil nil
                      (if value (symbol-name value) "unset"))))
         (unless (equal choice "unset") (intern choice))))
      ('string (read-string (format "%s: " label) value))
      (_ (user-error "maduin: unsupported config type for %s" label)))))

(defun maduin-cockpit-config--read-only-p (row)
  "Return non-nil when ROW is a harness identity field."
  (and (eq (plist-get row :section) 'harness)
       (memq (plist-get row :key) '(name version))))

(defun maduin-cockpit-config--apply (row value)
  "Apply VALUE to ROW, refresh the cockpit, and report its runtime scope.
Setter errors deliberately propagate unchanged so invalid values never look
like successful edits."
  (let ((section (plist-get row :section))
        (key (plist-get row :key)))
    (when (maduin-cockpit-config--read-only-p row)
      (user-error "maduin: harness/%s is read-only" key))
    (maduin-config-set-option section key value)
    (maduin-cockpit-refresh)
    (message "maduin: %s/%s = %s (runtime only — edit harness/config.el to persist)"
             section key (maduin-cockpit-config--value-string value))
    value))

(defun maduin-cockpit-config--edit (row)
  "Read and apply a new value for ROW."
  (when (maduin-cockpit-config--read-only-p row)
    (user-error "maduin: harness/%s is read-only" (plist-get row :key)))
  (maduin-cockpit-config--apply row (maduin-cockpit-config--read row)))

(defun maduin-cockpit-config--fallback ()
  "Select and edit a configuration row using built-in completion."
  (interactive)
  (let* ((rows (apply #'append (mapcar #'cdr (maduin-cockpit-config--rows))))
         (choices (mapcar (lambda (row)
                            (cons (maduin-cockpit-config--display row) row))
                          rows))
         (selection (completing-read "Maduin config: " (mapcar #'car choices) nil t))
         (row (cdr (assoc selection choices))))
    (unless row
      (user-error "maduin: unknown config option"))
    (maduin-cockpit-config--edit row)))

(defun maduin-cockpit-config--transient-command-name (row)
  "Return the generated transient command symbol for ROW."
  (intern (format "maduin-cockpit-config--%s-%s"
                  (plist-get row :section) (plist-get row :key))))

(defun maduin-cockpit-config--ensure-transient-prefix ()
  "Define the data-driven transient prefix after transient becomes available."
  (unless (fboundp 'maduin-cockpit-config--transient-prefix)
    (let ((index 0)
          groups)
      (dolist (group (maduin-cockpit-config--rows))
        (let ((section (car group))
              suffixes)
          (dolist (row (cdr group))
            (setq index (1+ index))
            (let ((command (maduin-cockpit-config--transient-command-name row)))
              (fset command
                    (eval `(lambda ()
                             (interactive)
                             (maduin-cockpit-config--edit ',row))))
              (push (list (format "%s %d" (substring (symbol-name section) 0 1)
                                  index)
                          (format "%s (%s)" (plist-get row :label)
                                  (maduin-cockpit-config--value-string
                                   (plist-get row :value)))
                          command)
                    suffixes)))
          (push (apply #'vector (capitalize (symbol-name section))
                       (nreverse suffixes))
                groups)))
      (setq groups (nreverse groups))
      (eval `(transient-define-prefix maduin-cockpit-config--transient-prefix ()
               "Maduin runtime configuration (edit harness/config.el to persist)"
               ,@groups)))))

;;;###autoload
(defun maduin-cockpit-config ()
  "Open the cockpit's runtime configuration panel.
Changes last only for this Emacs session; edit harness/config.el to persist.
Use a grouped transient menu when optional `transient' is present, otherwise
use the built-in completing-read fallback."
  (interactive)
  (if (and (fboundp 'transient-setup) (fboundp 'transient-define-prefix))
      (condition-case nil
          (progn
            (maduin-cockpit-config--ensure-transient-prefix)
            (transient-setup 'maduin-cockpit-config--transient-prefix))
        (error (maduin-cockpit-config--fallback)))
    (maduin-cockpit-config--fallback)))

(provide 'maduin-cockpit-config)

;;; maduin-cockpit-config.el ends here
