# super-harness-m0b.2 — workspace.el: per-seat worktree provisioning

## 交付

新檔 `harness/super-harness-workspace.el`（含 .elc 編譯產物）。

## 介面

- `(super-harness-workspace-ensure seat-name)` → worktree path 字串或 nil。既存（`super-harness-bd-worktree-list` 命中）→ 回傳其 path；缺失 → `make-directory` workspaces root（`t` 遞歸）後 `super-harness-bd-worktree-create`。建立失敗 → log warning（`super-harness-log` 存在則用之，否則 `message`；fboundp 守衛）→ nil。冪等。
- `(super-harness-workspace-path seat-name)` → 字串，`workspaces.path` + seat-name，不建立。
- `(super-harness-workspace-branch seat-name)` → 字串 = seat-name。
- `(super-harness-workspace-exists-p seat-name)` → 布林，依 bd worktree list。

私有：`super-harness-workspace--root`（config `workspaces.path`，缺省 `harness/workspaces`，expand 絕對路徑）、`super-harness-workspace--log-warning`。

Require：`cl-lib`、`super-harness-bd-bridge`、`super-harness-config`。`provide 'super-harness-workspace`。

## 驗證

- `emacs -Q --batch -L harness -l super-harness-workspace -f batch-byte-compile harness/super-harness-workspace.el` → 零警告零錯誤。
- 功能測試於 scratch git repo（`bd init` 後）：
  - `bd worktree create test --branch test` 預置 → `exists-p` t，`ensure` 重用既有 path（未重建）。
  - `ensure "bat"`（缺失）→ 建立新 worktree，`exists-p` t。
  - 再 `ensure "bat"` → 回傳同 path（冪等）。
  - `path "homer"` → `<repo>/harness/workspaces/homer`；`branch "homer"`。
- scratch repo 已清理。
