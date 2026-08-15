# maduin-aaa.1 — pipeline: close bead only after merge

## 改動

- `harness/maduin-pipeline.el`：
  - `maduin-pipeline-land-branch`：
    - 回 `t`（merge 成功）｜`'conflict`（merge 敗且輸出含 conflict
      — `CONFLICT`／`fix conflicts`／`merge conflict`，比對下寫
      `(string-match-p "conflict" (downcase out))`）｜`nil`
      （worktree 缺、commit 敗、非 conflict merge 敗）。
    - docstring 更新；`'conflict` 以 `\\='` 逸出，byte-compile 無警告。
  - `maduin-pipeline--poll` sentinel：閉合路徑反序 —
    先 `land-branch`，後 `bd-close`。
    - `t` → `(maduin-bd-close task output)`，唯此閉合。
    - `'conflict` → 不閉；shell 跑 `bd comment <id> "merge conflict — resolver dispatched"`；
      log-warning；留開；sentinel 回 `'conflict`。
    - `nil`（含 land 拋錯，condition-case 護）→ 不閉；
      shell 跑 `bd comment <id> "land failed — task left open"`；log-warning；留開。
    - 舊「先 close 後 land」路徑全刪。

## 介面

- `maduin-pipeline-land-branch` → `t` | `'conflict` | `nil`。
- poll 閉合：僅 `t` 時 `bd-close`；conflict／失敗留開 + 註。
- bd-bridge 無 `bd-comment` 函；經 `maduin-bd--run`
  shell 跑 `bd comment`（bd CLI 有 `comment` 子命令，驗過）。

## 驗證

- `emacs -Q --batch -l harness/maduin-pipeline.el
  -f batch-byte-compile harness/maduin-pipeline.el` — 淨，無警告。
- `emacs -Q --batch -L harness -l maduin-test
  --eval '(ert-run-tests-batch-and-exit "maduin-test-")'` —
  25/25 過，0 失敗。

## 注意

- `maduin.el` 內 `maduin-stop` 亦調 `land-branch`
  （舊介面 nil／t 兼容：conflict 時回 `'conflict`，該處僅判真偽 —
  未改動，不在本任務範圍）。

# maduin-aaa.4 — config + ERT tests for resolver

## 改動

- `harness/config.el`：加 resolver 段 —
  `(resolver . ((enabled . t) (model . "deepseek-v3") (max-retries . 3)))`。
- `harness/maduin.el`：
  - `(require 'maduin-resolver)`。
  - `maduin-stop`：既有停止邏輯後，遍歷
    `maduin-resolver-processes` 快照，逐座
    `maduin-resolver-stop`，condition-case 守護，不中斷停止。
  - `maduin-start`：不改 — 無自動 spawn，on-demand 唯。
- `harness/maduin-test.el`：加 6 測試（tag maduin）：
  - `config-resolver-keys`：enabled t、model "deepseek-v3"、max-retries 3。
  - `resolver-active-p-bogus`：虛席 → nil，無崩。
  - `resolver-prompt`：prompt 含席名 + `RESOLVED_DONE`。
  - `resolver-start-degraded`：opencode 缺 → 不誤；buffer 生；nil 回。
  - `resolver-start-fake-process`：sleep 偽程序 → active-p t → stop →
    active-p nil。
  - `resolver-stop-inactive`：虛席 stop → 不誤。
  - `config-workspaces-land-on-stop`（既有）留，回歸驗。

## 介面

- `maduin-config` resolver 段：`enabled` / `model` / `max-retries`。
- `maduin-stop` 現亦停 resolver 會話。

## 驗證

- byte-compile：淨（僅既有警告：pipeline 舊 .elc、
  `maduin-mode` defcustom group、resolver docstring 引號、
  `noninteractive` prefix — 皆前任務遺留）。
- ERT：31/31 過（25 舊 + 6 新），0 unexpected。
- full load：`emacs -Q --batch -l harness/maduin.el --eval '(message "OK")'` → OK，exit 0。

# maduin rename — 舊名（hyphen 式）→ maduin（專案/套件名；席名不改）

## 範圍
- 僅 PROJECT/PACKAGE 名。席名 ant/homer/plato/austen 留；FF 席改名屬 v0.2 另計。
- DB 名（下劃線式）不動 — 嵌於 `.beads/metadata.json`，遷移險。

## 改動
- Elisp 符號：`harness/*.el` 全舊前綴 → `maduin`
  （defun/defvar、provide/require、`maduin-mode`、hook、keymap、
  buffer `*maduin/*`、cockpit `*maduin-cockpit*`、test tag `maduin`）。
- `config.el`：`(name . "maduin")`；席名原樣。
- 檔名 `git mv`：12 前綴檔 + 主檔 → `maduin-*.el`／`maduin.el`。
  舊 `.elc` 四枚（config/resolver/test/main）刪 — stale 位元碼，重建。
- `install.sh`：marker/echo/require/end 全 maduin；`SNIPPET_MARKER` 獨有化；
  load-path 仍動態 `${HARNESS_DIR}`（pwd 派生，隨目錄移自動正）。
- Doom config（`~/.config/doom/config.el`）managed block：
  load-path → `/Users/connorfranc/code/maduin/harness`；`(require 'maduin)`；`(maduin-mode 1)`。
- 文檔：`.agents/brain/*.md`、`.agents/planning/maduin/**`
  （目錄 rename 用 plain `mv` — `.agents` gitignored）、`output.md`（根＋harness）。
- bd：`bd rename-prefix maduin-` — 28 issue 前綴舊名 → `maduin`。

## 驗證
- `emacs -Q --batch -l harness/maduin.el --eval '(message "MADUIN LOADED")'` → exit 0。
- ERT：`(ert-run-tests-batch-and-exit '(tag maduin))` → Ran 31, 0 unexpected。
- `rg 舊名`（除 .git/.beads）→ 空（docs/el 無殘留）。

## 遺留（待用戶）
- repo 目錄移名（現名）→ `/code/maduin`（未做，按命）。
- 4 worktree 滯後（ant/homer/plato/austen）。
- `.beads/interactions.jsonl` 歷史 issue ID 仍含舊前綴
  （被動匯出，`rename-prefix` 不覆；可接受）。
- 未 commit。
