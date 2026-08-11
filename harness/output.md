# super-harness-m0b.4 — pipeline: land fleet branch to main after close

## 改動

- `harness/super-harness-pipeline.el` 唯改此檔。
- 新增 `super-harness-pipeline--git (dir &rest args)` → exit status：
  `git -C DIR` 經 `call-process-shell-command` 執行。
- 新增 `super-harness-pipeline--git-output (dir &rest args)` → `(STATUS . OUTPUT)`。
- 新增 `super-harness-pipeline--main-root ()` → 主 repo 根：
  `(locate-library "super-harness")` 所在目錄，否則 `default-directory`。
- 新增 `super-harness-pipeline-land-branch (seat-name)` → boolean：
  1. worktree 缺失 → log WARN，nil。
  2. worktree 內 `git add -A`；`git diff --cached --quiet` 為 0（無 staged）→ t。
  3. staged 有物 → `git commit -m "task complete (seat-name)"`；
     失敗且輸出含 "nothing to commit" → 視成功。
  4. 主 repo 內 `git merge --no-ff BRANCH -m "land seat-name"`；
     失敗（衝突）→ log WARN，nil，不強制。
  5. 成功 → t。
- `super-harness-pipeline--poll` sentinel：task close 後
  `(condition-case ... (super-harness-pipeline-land-branch seat-name))` —
  失敗僅 log，不阻 poll 循環。sentinel 重寫（原括號失衡，let\* 早閉致
  proc 脫域；重構淨化）。
- `super-harness-pipeline-start-fleet` 括號修正（原 defun 未閉）。
- 新增 `(require 'super-harness-workspace)`。

## 介面

- `super-harness-pipeline-land-branch (seat-name)` → boolean
  — worktree 變更提交並 merge seat 分支入主 repo；無變更 t；衝突 nil。
- `super-harness-pipeline--git (dir &rest args)` → exit status（內部）。
- `super-harness-pipeline--git-output (dir &rest args)` → `(STATUS . OUTPUT)`（內部）。
- `super-harness-pipeline--main-root ()` → 主 repo 根路徑（內部）。

## 驗證

- `emacs -Q --batch -l harness/super-harness-pipeline.el -f batch-byte-compile` — 淨，無警告。
- 功能（/tmp scratch git repo，worktree + branch）：
  - A：worktree 提交一檔 → land-branch t；main log 見
    `land seat1` 與 `task complete (seat1)`。
  - B：無變更 → t，commit 數不增。
  - C：staged 衝突變更 → commit 後 merge 衝突 → nil，
    WARN log 現，main 未變、無 MERGING 殘留。
  - D：worktree 缺失 → nil + WARN。
