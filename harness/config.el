;;; config.el --- maduin configuration  -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(defvar maduin-config
  '((harness . ((name . "maduin") (version . "0.1.0")))
    (concierge . ((seats . (((name . "alexander") (role . concierge) (model . "opencode-go/deepseek-v4-pro"))))))
    (designer . ((seats . (((name . "ramuh") (role . designer) (model . "opencode-go/deepseek-v4-pro"))))))
    (fleet . ((seats . (((name . "ifrit") (role . implementer) (model . "opencode-go/deepseek-v4-flash"))
                        ((name . "shiva") (role . implementer) (model . "opencode-go/deepseek-v4-flash"))
                        ((name . "titan") (role . implementer) (model . "opencode-go/deepseek-v4-flash"))))
              (poll-interval . 30) (max-concurrent . 1)))
    (brain . ((path . ".agents/brain") (prime-files . ("architecture.md" "conventions.md"))))
    (welfare . ((handoff-enabled . t) (handoff-timeout . 120) (blameless . t)))
    (workspaces . ((path . "harness/workspaces") (land-on-stop . t)))
    (resolver . ((enabled . t) (model . "opencode-go/deepseek-v4-pro") (max-retries . 3)))
    (pipeline . ((review-required . nil) (auto-close-epic . t)))))

(provide 'maduin-config)

;;; config.el ends here
