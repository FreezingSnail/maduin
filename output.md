# super-harness-aaa.2 — resolver.el: dedicated beadle merge-conflict session

## 交付

新檔 `harness/super-harness-resolver.el`（含 .elc 編譯產物）。

## 介面

- `(super-harness-resolver-start seat-name)` → process 或 nil。已活躍（alist 有 live process）→ 返既有 process。config `resolver.enabled` nil → 返 nil（記 message）。`super-harness-session-create` role `resolver`、model 取 config `resolver.model`（缺省 `"deepseek-v3"`）、workdir `(super-harness-workspace-path seat-name)`。`default-directory` 設為 workdir。opencode 缺失 → buffer 仍建、process nil（degraded，不崩）。process 記入 `super-harness-resolver-processes`（alist，seat → process，含 nil 項）。
- `(super-harness-resolver-active-p seat-name)` → 布林。process 存在且 `process-live-p`；nil 安全。
- `(super-harness-resolver--prompt seat-name)` → 字串。Beadle 提示詞，替換 `{seat}`、`{path}`（workspace path）。
- `(super-harness-resolver-stop seat-name)` → 布林。alist 除項 + `super-harness-session-kill`（殺 process + buffer）。

私有：`super-harness-resolver--config-get`（存在即取、值可為 nil、缺 key 才 fallback default）、`super-harness-resolver--prime`（process live → `process-send-string`；否則插入 buffer，仿 agent-prime degrade）。

Require：`cl-lib`、`super-harness-session`、`super-harness-workspace`、`super-harness-config`（先 `add-to-list load-path` 以支持直載）。`provide 'super-harness-resolver`。`defvar super-harness-resolver-processes`。

## 驗證

- `emacs -Q --batch -l harness/super-harness-resolver.el -f batch-byte-compile harness/super-harness-resolver.el` → 零警告零錯誤。
- 功能測試（`super-harness-opencode-command` 設為不存在名，模擬 opencode 缺失）：
  - `start "zz-test"` → nil，無崩；buffer `*super-harness/resolver-zz-test*` 存在，role `resolver`、model `"deepseek-v3"`、workdir `<repo>/harness/workspaces/zz-test`。
  - `active-p` nil（無 process）。
  - `stop` → t；事後 `active-p` nil，buffer 滅。
  - `resolver.enabled . nil` 注入 config → `start` nil，buffer 未建。
  - prompt 文本含 seat、worktree path、branch、RESOLVED_DONE，合 spec。
