;;; maduin-config.el --- configuration  -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'project)

;; Real config lives in harness/config.el (single source of truth).
;; Load it so (require 'maduin-config) resolves the value.
(load-file (expand-file-name "config.el"
                             (file-name-directory load-file-name)))

(defun maduin-project-root ()
  "Return the root directory of the current project, as a string.
Use `project-root' of `project-current'; fall back to
`default-directory' when not inside a project."
  (let ((proj (project-current)))
    (if proj
        (project-root proj)
      default-directory)))

(provide 'maduin-config)

;;; maduin-config.el ends here
