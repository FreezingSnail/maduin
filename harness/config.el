;;; config.el --- maduin configuration  -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(defvar maduin-config
  '((harness . ((name . "maduin") (version . "0.3.0")))
    ;; Set `backend' to opencode or kiro to override every crew seat.
    ;; Nil preserves each seat's and role's configured backend.
    (crew . ((backend . nil)))
    (concierge . ((agent . "slugineer-planner-concierge")
                  (backend . opencode)
                  (model . "opencode-go/deepseek-v4-pro")
                  (kiro-model . "gpt-5.6-terra")
                  (kiro-fallback . "deepseek-3.2")
                  (seats . (((name . "alexander") (role . concierge)
                             (model . "opencode-go/deepseek-v4-pro"))))))
    (designer . ((agent . "slugineer-planner-designer")
                 (backend . opencode)
                 (model . "opencode-go/deepseek-v4-pro")
                 (kiro-model . "gpt-5.6-terra")
                 (kiro-fallback . "qwen3-coder-next")
                 (seats . (((name . "ramuh") (role . designer)
                            (model . "opencode-go/deepseek-v4-pro"))))))
    (fleet . ((agent . "slugineer-worker")
              (backend . opencode)
              (model . "opencode/deepseek-v4-flash-free")
              (kiro-model . "qwen3-coder-next")
              (kiro-model-low . "gpt-5.6-luna")
              (kiro-model-high . "gpt-5.6-terra")
              (kiro-effort-low . "medium")
              (kiro-effort-high . "high")
              (effort-low . nil)
              (effort-high . nil)
              (kiro-fallback . "minimax-m2.1")
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
                 (kiro-model . "gpt-5.6-terra")
                 (kiro-fallback . "deepseek-3.2")
                 (seats . (((name . "odin") (role . reviewer))))
                 (max-retries . 3)))
    (repairer . ((enabled . t) (agent . "slugineer-repairer")
                 (backend . opencode)
                 (esper . "phoenix") (model . "opencode-go/deepseek-v4-pro")
                 (kiro-model . "deepseek-3.2")
                 (kiro-fallback . "qwen3-coder-next")
                 (seats . (((name . "phoenix") (role . repairer))))
                 (max-retries . 3)))
    (welfare . ((handoff-timeout . 120)))
    (workspaces . ((path . "harness/workspaces") (land-on-stop . t)))))

(provide 'maduin-config)

;;; config.el ends here
