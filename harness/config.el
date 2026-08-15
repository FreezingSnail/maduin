;;; config.el --- maduin configuration  -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(defvar maduin-config
  '((harness . ((name . "maduin") (version . "0.3.0")))
    (concierge . ((agent . "slugineer-planner-concierge")
                  (seats . (((name . "alexander") (role . concierge)
                             (model . "opencode-go/deepseek-v4-pro"))))))
    (designer . ((agent . "slugineer-planner-designer")
                 (seats . (((name . "ramuh") (role . designer)
                            (model . "opencode-go/deepseek-v4-pro"))))))
    (fleet . ((agent . "slugineer-worker")
              (seats . (((name . "ifrit") (role . implementer)
                         (model . "opencode-go/deepseek-v4-flash"))
                        ((name . "shiva") (role . implementer)
                         (model . "opencode-go/deepseek-v4-flash"))
                        ((name . "titan") (role . implementer)
                         (model . "opencode-go/deepseek-v4-flash"))))
              (poll-interval . 30) (max-concurrent . 1)))
    (reviewer . ((enabled . t) (agent . "slugineer-reviewer")
                 (esper . "odin") (model . "opencode-go/deepseek-v4-pro")
                 (batch-size . 3) (max-retries . 3)))
    (repairer . ((enabled . t) (agent . "slugineer-repairer")
                 (esper . "phoenix") (model . "opencode-go/deepseek-v4-pro")
                 (max-retries . 3)))
    (brain . ((path . ".agents/brain") (prime-files . ("architecture.md" "conventions.md"))))
    (welfare . ((handoff-enabled . t) (handoff-timeout . 120) (blameless . t)))
    (workspaces . ((path . "harness/workspaces") (land-on-stop . t)))
    (pipeline . ((review-required . t) (auto-close-epic . t)))))

(provide 'maduin-config)

;;; config.el ends here
