# super-harness-m0b.5 — integration: bootstrap worktrees + land on stop + tests

## 改動

- `harness/config.el`：`workspaces` 節加 `(land-on-stop . t)`。
  保留 `workspaces` 鍵名（workspace.el 讀 `workspaces.path`，pipeline.el 讀 `workspaces` 節），
  不更名 `workspace`。
- `harness/super-harness.el`：
  - 加 `(require 'super-harness-workspace)`。
  - `super-harness-bootstrap`：建目錄後，對 `super-harness--seats`（crew+fleet）
    每 seat 調 `super-harness-workspace-ensure`，`condition-case` 護 —
    失敗僅 log，不崩。
  - `super-harness-stop`：handoff-stop-all 後，若 `workspaces.land-on-stop` 真，
    對每 fleet seat 調 `super-harness-pipeline-land-branch`，
    `condition-case` 護 — 失敗 log，不阻 stop。
- `harness/super-harness-test.el`：加 5 測試（tag super-harness）：
  - `workspace-path` 正路徑
  - `workspace-exists-p` bogus seat → nil
  - `bootstrap` 不拋錯（真建 worktree）
  - `land-branch` bogus seat → nil（護）
  - config `workspaces.land-on-stop` → t

## 介面

- `super-harness-bootstrap` → worktrees 對全部 seat ensure；失敗 log+nil，無崩。
- `super-harness-stop` → handoff 後 fleet 分支 land；`workspaces.land-on-stop`
  控制，預設 t。
- config `workspaces.land-on-stop`（boolean）。

## 驗證

- `emacs -Q --batch -l harness/super-harness.el -f batch-byte-compile
  harness/super-harness.el harness/super-harness-test.el` — 淨。
  唯既存 `super-harness-mode` defcustom group 警告（舊碼，非本次）。
- `emacs -Q --batch -l harness/super-harness-test.el
  --eval "(ert-run-tests-batch-and-exit '(tag super-harness))"` —
  25/25 過（20 舊 + 5 新），0 失敗。
- bootstrap 實跑：`bd worktree create` 成功，5 worktree 建
  （ant/bat/homer/plato/austen + 各分支），無崩。

## 注意（非本任務範圍）

- `bd worktree create` 將 worktree 建於項目根（如 `/super-harness/ant`），
  而 `super-harness-workspace-path` 返回 `harness/workspaces/ant`（空目錄）。
  分歧源於 bd CLI 建位，屬 workspace/bd-bridge 上游設計；
  本任務唯整合調用，不改其邏輯。
