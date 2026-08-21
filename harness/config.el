;;; config.el --- maduin configuration  -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(defvar maduin-config
  '((harness . ((name . "maduin") (version . "0.3.0")))
    (concierge . ((agent . "slugineer-planner-concierge")
                  (backend . opencode)
                  (seats . (((name . "alexander") (role . concierge)
                             (model . "opencode-go/deepseek-v4-pro"))))))
    (designer . ((agent . "slugineer-planner-designer")
                 (backend . opencode)
                 (seats . (((name . "ramuh") (role . designer)
                            (model . "opencode-go/deepseek-v4-pro"))))))
    (fleet . ((agent . "slugineer-worker")
              (backend . opencode)
              (seats . (((name . "ifrit") (role . implementer)
                         (model . "opencode/deepseek-v4-flash-free"))
                        ((name . "shiva") (role . implementer)
                         (model . "opencode/deepseek-v4-flash-free"))
                        ((name . "titan") (role . implementer)
                         (model . "opencode/deepseek-v4-flash-free"))))
              ;; Free-flash usage bucket is limited; fall back to the paid
              ;; go flash bucket on a usage/rate-limit failure.
              (fallback . "opencode-go/deepseek-v4-flash")
              (poll-interval . 30)))
    (reviewer . ((enabled . t) (agent . "slugineer-reviewer")
                 (backend . opencode)
                 (esper . "odin") (model . "opencode-go/deepseek-v4-pro")
                 (seats . (((name . "odin") (role . reviewer))))
                 (max-retries . 3)))
    (repairer . ((enabled . t) (agent . "slugineer-repairer")
                 (backend . opencode)
                 (esper . "phoenix") (model . "opencode-go/deepseek-v4-pro")
                 (seats . (((name . "phoenix") (role . repairer))))
                 (max-retries . 3)))
    (welfare . ((handoff-timeout . 120)))
    (workspaces . ((path . "harness/workspaces") (land-on-stop . t)))))

(provide 'maduin-config)

;;; config.el ends here
