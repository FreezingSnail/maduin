# output — super-harness-aaa.3

## 改

- `harness/super-harness-pipeline.el`:
  - 頂加 `(condition-case nil (require 'super-harness-resolver) (error nil))`
  - `super-harness-pipeline--poll` conflict 路徑: resolver 未活時 `super-harness-resolver-start seat-name`; 繼 `super-harness-resolver-register seat-name task`
- `harness/super-harness-resolver.el`:
  - 加 defvar `super-harness-resolver-pending-tasks` (seat . task-id)、`super-harness-resolver-retries` (seat . count)
  - 加 `super-harness-resolver-register seat-name task-id` → 存 pending、retries 置 1
  - 加 `super-harness-resolver-attach-sentinel proc seat-name` → 掛 sentinel; batch/non-interactive 守護 `(bound-and-true-p noninteractive)`
  - 加 `super-harness-resolver--on-exit proc seat-name` → 掃 buffer `RESOLVED_DONE`:
    - 有 → re-land: t → `super-harness-bd-close task-id` + 清 pending/retries + `super-harness-resolver-stop`
    - 仍 conflict → retries < `resolver.max-retries` (default 3) → 再 start; 盡 → log、task 留開
    - nil → log、task 留開
    - 無 marker → log、task 留開
  - `super-harness-resolver-start` 內 spawn 後掛 sentinel

## 介面

- `super-harness-resolver-register` — (seat-name task-id) → void; pipeline 派 resolver 時記 pending
- `super-harness-resolver-attach-sentinel` — (proc seat-name) → void; 掛完成 sentinel
- `super-harness-resolver-pending-tasks` — alist (seat . task-id)
- `super-harness-resolver-retries` — alist (seat . count)

## 驗證

- `emacs -Q --batch -l harness/super-harness-pipeline.el -l harness/super-harness-resolver.el -f batch-byte-compile` — 淨
- ERT 25/25 pass（tag super-harness）

## 註

- config 無 resolver 段 → max-retries default 3
- 成功 re-land 時 `super-harness-bd-close` 以 nil output 呼叫（不覆寫 agent output.md）
- retries 計數: register 置 1; 每次 conflict 後 +1; 至 max 即棄
