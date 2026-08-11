# output.md — super-harness-c7d.2 (bd-bridge.el)

## 介面

`harness/super-harness-bd-bridge.el` 提供：

```
(super-harness-bd-ready-tasks)                    ;; → list of task ID strings (epics excluded)
(super-harness-bd-claim task-id)                  ;; → t | nil
(super-harness-bd-close task-id output)           ;; → t | nil
(super-harness-bd-create-epic title desc)         ;; → epic ID string | nil
(super-harness-bd-create-task title desc parent-id) ;; → task ID string | nil
(super-harness-bd-dep-add task-id depends-on-id)  ;; → t | nil
(super-harness-bd-show task-id)                   ;; → plist (:title :desc :status :deps) | nil
(super-harness-bd-remember fact)                  ;; → t | nil
(super-harness-bd-prime)                          ;; → string (bd prime output) | nil
```

## 契約

- **ready-tasks**: `bd ready --exclude-type epic --json`；JSON 陣列取 `id` 欄。退出碼非零 → nil + log。
- **claim**: `bd update <id> --claim`（原子 claim，冪等）。exit 0 → t。
- **close**: 先以 `output` 寫入 `super-harness-bd-close-file`（預設 `output.md`，`default-directory` 下），再 `bd close <id> --reason-file <file>`。exit 0 → t。
- **create-epic / create-task**: `bd create <title> --type epic|task --silent --description <desc> [--parent <id>]`；`--silent` 輸出純 ID，`string-trim` 取之。空 → nil。
- **dep-add**: `bd dep add <task-id> <depends-on-id>`。exit 0 → t。
- **show**: `bd show <id> --json` 取 `title`/`description`/`status`；`bd dep list <id> --json` 取 `id` 列表為 `:deps`。
- **remember**: `bd remember <fact>`。exit 0 → t。
- **prime**: `bd prime` 原樣返回輸出字串；失敗 → nil。
- **執行**: `super-harness-bd--run` 用 `call-process shell-file-name`（返回 `(exit-code . output)`）；JSON 用 `json-read-from-string`（陣列轉 list）。
- **錯誤**: 非零退出 → `super-harness-bd--log-error`（`super-harness-log` 若可用，否則 `message`）；返回 nil。
- **依賴**: `(require 'cl-lib)`、`(require 'json)`、`(require 'super-harness-logging nil t)`（guard）。
- `(provide 'super-harness-bd-bridge)`。

## 驗證

`emacs -Q --batch -l harness/super-harness-bd-bridge.el -f batch-byte-compile` → exit 0。
自測: ready 列 task、create-task → ID、dep-add → t、show 之 :deps 含父+依賴、close → t（`/tmp` 輸出檔）、remember → t、prime 長字串、bad-id → nil + log。
