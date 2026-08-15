;;; maduin-config.el --- configuration  -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

;; Real config lives in harness/config.el (single source of truth).
;; Load it so (require 'maduin-config) resolves the value.
(load-file (expand-file-name "config.el"
                             (file-name-directory load-file-name)))

(provide 'maduin-config)

;;; maduin-config.el ends here
