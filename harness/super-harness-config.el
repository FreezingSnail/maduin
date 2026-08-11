;;; super-harness-config.el --- configuration  -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

;; Real config lives in harness/config.el (single source of truth).
;; Load it so (require 'super-harness-config) resolves the value.
(load-file (expand-file-name "config.el"
                             (file-name-directory load-file-name)))

(provide 'super-harness-config)

;;; super-harness-config.el ends here
