;;; config.el --- super-harness configuration  -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(defvar super-harness-config
  '((harness . ((name . "super-harness") (version . "0.1.0")))
    (crew . ((seats . (((name . "ant") (model . "deepseek-v3"))
                       ((name . "bat") (model . "deepseek-v3"))))))
    (fleet . ((seats . (((name . "homer") (model . "deepseek-v3"))
                        ((name . "plato") (model . "deepseek-v3"))
                        ((name . "austen") (model . "deepseek-v3"))))
              (poll-interval . 30) (max-concurrent . 1)))
    (brain . ((path . ".agents/brain") (prime-files . ("architecture.md" "conventions.md"))))
    (welfare . ((handoff-enabled . t) (handoff-timeout . 120) (blameless . t)))
    (workspaces . ((path . "harness/workspaces") (land-on-stop . t)))
    (pipeline . ((review-required . nil) (auto-close-epic . t)))))

(provide 'super-harness-config)

;;; config.el ends here
