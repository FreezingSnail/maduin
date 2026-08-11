# super-harness-m0b.1 — bd-bridge: worktree wrappers

## 介面

`harness/super-harness-bd-bridge.el` 新增三函數（`provide` 前）：

- `(super-harness-bd-worktree-create name)` → path string 或 nil
  - 執行 `bd worktree create <name> --branch <name>`
  - 從輸出 `✓ Created worktree: <path>` 解析；不獲則退 `(super-harness-bd-worktree-list)` 查 name
- `(super-harness-bd-worktree-list)` → alist `((name . path) ...)`
  - 主 `bd worktree list --json`（name/path 欄位）；失敗退 `git worktree list --porcelain`（name 取自路徑 basename）
- `(super-harness-bd-worktree-info dir)` → plist `(:path :branch :name)` 或 nil
  - 執行 `git -C <dir> worktree list --porcelain`，篩 path 相等之條目
  - （`git worktree info` 子命令不存在於 git 2.50；用 list --porcelain）

私助（`--` 前綴）：`super-harness-bd-worktree--entry`、`--porcelain-entries`（容 detached 無 branch）、`--parse-created-path`。

## 錯誤處理

沿襲既有：`super-harness-bd--run` + 退出碼檢查；失敗經 `super-harness-bd--log-error`，回 nil。

## 驗證

- 編譯：`emacs -Q --batch -l harness/super-harness-bd-bridge.el -f batch-byte-compile` — 淨，exit 0
- 功能（暫存庫 `~/.wt-test-scratch`，git init + bd init 後）：
  - list → `(("wt-test-scratch" . "…/.wt-test-scratch") ("x" . "…/x") ("y" . "…/y"))` ✓
  - create `z` → `"…/.wt-test-scratch/z"` ✓
  - info `z` → `(:path "…/z" :branch "z" :name "z")` ✓
  - info 不存在目錄 → nil + error log ✓
  - 事後 `git worktree remove --force z`，刪暫存庫 ✓
