# super-harness-aaa.1 — pipeline: close bead only after merge

## 改動

- `harness/super-harness-pipeline.el`：
  - `super-harness-pipeline-land-branch`：
    - 回 `t`（merge 成功）｜`'conflict`（merge 敗且輸出含 conflict
      — `CONFLICT`／`fix conflicts`／`merge conflict`，比對下寫
      `(string-match-p "conflict" (downcase out))`）｜`nil`
      （worktree 缺、commit 敗、非 conflict merge 敗）。
    - docstring 更新；`'conflict` 以 `\\='` 逸出，byte-compile 無警告。
  - `super-harness-pipeline--poll` sentinel：閉合路徑反序 —
    先 `land-branch`，後 `bd-close`。
    - `t` → `(super-harness-bd-close task output)`，唯此閉合。
    - `'conflict` → 不閉；shell 跑 `bd comment <id> "merge conflict — resolver dispatched"`；
      log-warning；留開；sentinel 回 `'conflict`。
    - `nil`（含 land 拋錯，condition-case 護）→ 不閉；
      shell 跑 `bd comment <id> "land failed — task left open"`；log-warning；留開。
    - 舊「先 close 後 land」路徑全刪。

## 介面

- `super-harness-pipeline-land-branch` → `t` | `'conflict` | `nil`。
- poll 閉合：僅 `t` 時 `bd-close`；conflict／失敗留開 + 註。
- bd-bridge 無 `bd-comment` 函；經 `super-harness-bd--run`
  shell 跑 `bd comment`（bd CLI 有 `comment` 子命令，驗過）。

## 驗證

- `emacs -Q --batch -l harness/super-harness-pipeline.el
  -f batch-byte-compile harness/super-harness-pipeline.el` — 淨，無警告。
- `emacs -Q --batch -L harness -l super-harness-test
  --eval '(ert-run-tests-batch-and-exit "super-harness-test-")'` —
  25/25 過，0 失敗。

## 注意

- `super-harness.el` 內 `super-harness-stop` 亦調 `land-branch`
  （舊介面 nil／t 兼容：conflict 時回 `'conflict`，該處僅判真偽 —
  未改動，不在本任務範圍）。
