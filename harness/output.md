# maduin-00r.6 — concierge (Alexander): epic discussion TUI + dismiss→bd

## 改動

- `harness/maduin-concierge.el`（新）— concierge 角色（Alexander），
  Summoner 單一對口；按 epic 討論需召喚、議畢即遣散，**非持久** session。
  - `(maduin-concierge)` — M-x 召喚：`maduin-terminal-open` 開
    opencode TUI，prime concierge 角色模板。回 terminal buffer。
  - `(maduin-concierge-dismiss)` — M-x 遣散：`maduin-terminal-dismiss`
    → export → handoff note → kill buffer；回 handoff note｜nil。
    epic + HIGH-LEVEL（deferred）task 由 concierge 於 TUI 內自行
    bd 呼叫完成 — elisp 不代跑 bd。
  - 注入縫（defvar fn slot，鏡像 maduin-dispatch.el）：
    `maduin-concierge--terminal-open-fn`／`--terminal-dismiss-fn`。
  - model 自 config 解析（非硬編）：`maduin-concierge--seat-model seat`
    讀 `(concierge seats)` by-name；`--model` → concierge 席 model。
  - `maduin-concierge--seat` defvar = "alexander"（可覆寫）。
- `harness/templates/concierge-prompt.txt`（新）— 模板以 `{name}`
  placeholder 起頭（經 `maduin-terminal--substitute` 換 "alexander"），
  含必要指令：epic、HIGH-LEVEL、`--defer`、Do not design、Do not implement。
- `harness/maduin.el`：
  - `(require 'maduin-concierge)`。
  - 刪舊 `maduin-concierge (work)`（v0.1 pipeline dispatch 版）—
    新定義在 maduin-concierge.el（`C-c s c` 綁定照舊指向新函數）。
  - keymap 加 `C-c s d` → `maduin-concierge-dismiss`。
  - `maduin--feature-list` 加 `maduin-concierge`（reload 覆蓋）。

## 介面

- `maduin-concierge`        → buffer（interactive）
- `maduin-concierge-dismiss` → handoff note string｜nil
- `maduin-concierge--seat-model SEAT` → model string（alexander →
  `opencode-go/deepseek-v4-pro`）

## 驗證

- `emacs -Q --batch -L harness -l maduin-test
  --eval '(ert-run-tests-batch-and-exit "maduin-test-")'` →
  73/73 過，0 unexpected（68 舊 + 5 新 concierge 測）。
- byte-compile `maduin-concierge.el` 淨，無警告（.elc 已移除）。

## 注意

- 未手動 commit（auto-commit watcher 處理）。

# maduin-00r.5 — demand-driven ephemeral session dispatcher

## 改動

- `harness/maduin-dispatch.el`（新）— deterministic dispatcher，取代
  v0.1「起 N 席」為 zero-idle、併發上限 dispatch。
  - `(maduin-dispatch-start)`／`(maduin-dispatch-stop)` — 啟／停 run-loop
    timer；start **不 spawn 任何 session**。
  - `(maduin-dispatch-implement task)` → handle｜nil — claim + 挑自由席
    （ifrit/shiva/titan，cap 3 併發）+ session-run 注入 plan。
  - `(maduin-dispatch-design task)` → handle｜nil — Ramuh design session。
  - `(maduin-dispatch-resolve seat task)` → handle｜nil — Phoenix resolve。
  - `(maduin-dispatch-run-loop)` — poll `bd ready`，逐 ready task dispatch。
  - 完成：`maduin-session-on-complete-hook` →
    `completed`：diff → `maduin-pipeline-land-branch` → `maduin-bd-close`；
    `failed`：comment + 留開；land conflict → dispatch resolver（非
    resolver 席則派，resolver 席則留開防無限迴圈）。
  - session 完成即 delete（ephemeral — session 僅在有 work 時存在）。
- 併發：active registry（`:handle :seat :role :task` plist）；cap = 席數
  （implementer 3、designer 1、resolver 1）。滿席 → nil 不 spawn。
- 注入縫（defvar fn slot，測試 mock，不 spawn 真 opencode）：
  `--session-run-fn`／`--session-delete-fn`／`--diff-fn`／`--land-fn`／
  `--close-fn`／`--claim-fn`／`--ready-fn`／`--show-fn`／`--comment-fn`／
  `--workdir-fn`。
- plan 注入：`bd show` title+desc → plan string（沿用 pipeline 措辭）。
- land/close 單一真源：`maduin-pipeline-land-branch` + `maduin-bd-close`
  （pipeline 未改，dispatch 只調用）。

## 介面

- `maduin-dispatch-start/stop/run-loop`  — lifecycle
- `maduin-dispatch-implement/design/resolve` → session handle | nil

## 驗證

- `emacs -Q --batch -L harness -l maduin-test
  --eval '(ert-run-tests-batch-and-exit "maduin-test-")'`
  → 68/68 過，0 unexpected（61 舊 + 7 新 dispatch 測）。
- byte-compile `maduin-dispatch.el` 淨，無警告。

## 注意

- 未手動 commit（auto-commit watcher 處理）。

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

# maduin-00r.1 — project scoping: (maduin-project-root)

## 改動

- `harness/maduin-config.el`：加 `(maduin-project-root)` —
  `(project-root (project-current))`，非 project 回 `default-directory`。
  `(require 'project)`。
- `harness/maduin-brain.el`：`maduin-brain-root` 於 project root 下解析；
  `fboundp` 守護（config 缺時回 `default-directory`）。
- `harness/maduin-handoff.el`：`maduin-handoff-cache-path` 於 project root 下解析。
- `harness/maduin-workspace.el`：`maduin-workspace--root` 於 project root 下解析。
- `harness/maduin-session.el`：`maduin-session-create` WORKDIR 變可選，
  缺省 `(maduin-project-root)`（fboundp 守護）。
- `harness/maduin.el`：`maduin--seat-workdir` 於 project root 下解析（一致性）。
- `harness/maduin-test.el`：+3 ERT（`project-root-returns-dir`、
  `project-root-fallback`、`handoff-cache-under-project-root`）；
  `workspace-path` 測更新為 project root 期望。

## 介面

- `(maduin-project-root)` → string path（project.el 倉根；無 project 回 default-directory）。

## 驗證

- `emacs -Q --batch -L harness -l maduin-test
  --eval '(ert-run-tests-batch-and-exit "maduin-test-")'` →
  34/34 過（31 舊 + 3 新），0 unexpected。
- byte-compile 淨（僅既有警告：handoff-wait `buf` free var、
  `maduin-mode` defcustom group）。

# maduin-00r.2 — FF seats + model config (alexander/ramuh/ifrit/shiva/titan/phoenix)

## 改動

- `harness/config.el`：席段全換 FF 名 —
  - `concierge` → alexander（role `concierge`，model `opencode-go/deepseek-v4-pro`）。
  - `designer` → ramuh（role `designer`，model `opencode-go/deepseek-v4-pro`）。
  - `fleet` → ifrit/shiva/titan（role `implementer`，model `opencode-go/deepseek-v4-flash`）。
    `poll-interval` 30、`max-concurrent` 1 留。
  - `resolver`（Phoenix）→ `enabled t`、model `opencode-go/deepseek-v4-pro`、`max-retries 3`。
  - 舊 `crew`/ant/homer/plato/austen 段全刪。
- `harness/maduin.el`：
  - `maduin--seats`：遍歷 `(concierge designer fleet)`，取席名 +
    `(symbol-name (alist-get 'role s))` → 回 `((SEAT . ROLE-string) ...)`。
  - `maduin--seat-model`：改單參 `seat`，跨三段 by-name 查 `model`。
  - `maduin-start`：`(maduin--seat-model seat)`；`(string= role "implementer")`
    才 `maduin-pipeline-start-fleet`。
  - `maduin-stop`：land-branch 判 `"implementer"`（原 `"fleet"`）。
  - `maduin-crew` → `maduin-concierge`（keybinding `C-c s c` 留，c=concierge）。
- `harness/maduin-pipeline.el`：
  - `maduin-pipeline--crew-seats` → `--concierge-seats`（讀 `concierge`）；
    加 `--designer-seats`（讀 `designer`）。
  - `maduin-pipeline-find-free-agent`：role `"concierge"|"designer"|"implementer"`
    分支映射三段席。
  - `maduin-pipeline-dispatch-crew` → `maduin-pipeline-dispatch-concierge`（找 concierge）。
  - `maduin-pipeline--poll`：spawn role `"implementer"`（原 `"fleet"`）。
- `harness/maduin-cockpit.el`：`maduin-cockpit--seats` 三段
  concierge/designer/implementer 對位（原 crew/fleet）。
- `harness/maduin-agent.el`：`maduin-agent--template` role 映射 —
  `"implementer"` → `fleet-prompt.txt`，餘 → `crew-prompt.txt`；
  `maduin-agent-prime` 缺省 role `"concierge"`。templates 檔案名不改（本任務只 plumbing）。
- `harness/maduin-resolver.el`：`maduin-resolver-start` docstring + 缺省 model
  → `opencode-go/deepseek-v4-pro`（docstring 內不帶引號，避字串終止）。
- `harness/maduin-workspace.el`：**無改** — worktree 路徑自席名派生，
  無硬編席名；新席於下次 `maduin-bootstrap` 建 alexander/ramuh/ifrit/shiva/titan。

## 介面

- `(maduin--seats)` → `(("alexander" . "concierge") ("ramuh" . "designer")
  ("ifrit" . "implementer") ("shiva" . "implementer") ("titan" . "implementer"))`。
- `(maduin--seat-model SEAT)` → model string（pro：alexander/ramuh；
  flash：ifrit/shiva/titan）。
- 模型 ID：`opencode-go/deepseek-v4-pro`（concierge/designer/resolver）、
  `opencode-go/deepseek-v4-flash`（implementers）— 已 `opencode models` 核實。

## 驗證

- `emacs -Q --batch -L harness -l maduin-test
  --eval '(ert-run-tests-batch-and-exit "maduin-test-")'` →
  41/41 過，0 unexpected。
  （本任務測試 37 枚含新 `config-seats`/`config-seat-models` 與改寫之
  concierge/designer/fleet/resolver 測；餘 4 枚 gate 測屬並行任務 maduin-gate。）

## 注意

- 無舊 `crew`/`ant`/`homer`/`plato`/`austen` 殘留（除 output.md 歷史、
  agent 內 template 檔名映射 `fleet`/`crew`）。
- 未手動 commit（auto-commit watcher 處理）。

# maduin-00r.8 — approval gate: stage/approve/reject via defer-undefer + staged label

## 改動

- `harness/maduin-bd-bridge.el`：+7 gate wrappers（沿用既有
  `maduin-bd--run`／`--log-error`／`shell-quote-argument` 風格）：
  - `(maduin-bd-defer id)` → boolean — `bd defer <id>`（無 `--until`
    = 無限期延遲）。
  - `(maduin-bd-undefer id)` → boolean — `bd undefer <id>`（不級聯子項）。
  - `(maduin-bd-label id label)` → boolean — `bd label add <id> <label>`。
  - `(maduin-bd-label-remove id label)` → boolean — `bd label remove <id> <label>`。
  - `(maduin-bd-query q)` → id list — `bd query <q> --json`，經
    `maduin-bd--json-ids` 取 `id` 欄。
  - `(maduin-bd-comment id text)` → boolean — `bd comment <id> <text>`。
  - `(maduin-bd-update-design-acceptance id design acceptance)` → boolean —
    `bd update <id> --design ... --acceptance ...`。
- `harness/maduin-gate.el`（新）：
  - `(maduin-gate-stage task design acceptance)` → boolean —
    update design/acceptance + defer + `label add staged`。
  - `(maduin-gate-approve id)` → boolean — undefer + `label remove staged`。
  - `(maduin-gate-reject id feedback)` → boolean — `bd comment`；留 staged。
  - `(maduin-gate-staged-list)` → id list — `bd query
    "status=deferred AND label=staged"`。
  - `(maduin-gate-approve-epic epic-id)` → approved id list — 逐子項 approve
    （`bd query "parent=<epic> AND status=deferred AND label=staged"`，
    undefer 不級聯，故迴圈）。
  - `maduin-gate-staged-label` = `"staged"`。
- `harness/maduin.el`：`(require 'maduin-gate)`；`maduin--feature-list`
  加 `maduin-gate`（bd-bridge 前，leaf-first）。
- `harness/maduin-test.el`：+4 ERT（tag maduin）— gate functions-exist、
  stage-approve-list、reject-keeps-staged、approve-epic。scratch 珠
  （timestamp 命名 epic+task）建於 repo 自身 `.beads`，測後
  `bd delete <id> --force` 自清理。

## 介面

- bd wrappers：`maduin-bd-defer/undefer/label/label-remove/query/comment/
  update-design-acceptance`。
- gate API：`maduin-gate-stage/approve/reject/staged-list/approve-epic`。

## reject 回饋機制（選定）

- `bd comment <id> <text>`（`bd --help` 有 `comment` 子命令，驗過）—
  bd-native，append 到 issue 註解串；task 保持 staged（deferred + label）。
  未採 `bd update --body`（body 為描述，非回饋串）。

## 驗證

- `emacs -Q --batch -L harness -l maduin-test
  --eval '(ert-run-tests-batch-and-exit "maduin-test-")'` →
  41/41 過，0 unexpected（含 4 gate 測：stage→staged-list 含→approve→除、
  reject→仍 staged、approve-epic→兩子全除、functions-exist）。
- byte-compile：`maduin-gate.el`／`maduin-bd-bridge.el` 淨，無警告。

## 注意

- `bd label add/remove` 語法 = `bd label add <issue-id...> [label]`（驗過，
  非 spike 猜測）。
- 早前一次全量跑見 2 resolver 測 `void-variable opencode-go/deepseek-v4-pro`
  失敗 — 並行任務（ifrit）改 config/resolver 途中之暫態，非本任務；
  commit `dac54b1` 落定後復跑 41/41 綠。
- 未手動 commit（auto-commit watcher 已併入 `dac54b1`）。

# maduin-00r.4 — interactive session substrate: opencode TUI in terminal buffer

## 改動

- `harness/maduin-terminal.el`（新）：
  - `(maduin-terminal-open seat role model)` → buffer —
    於 `(maduin-project-root)` 開 vterm（缺則 `term`），啟動
    `opencode <root> -m <model> --prompt <role-template>`（TUI，互動）；
    設 buffer-local 狀態（seat/role/model/root/session-id/started-at/known-ids）。
  - `(maduin-terminal-dismiss seat)` → handoff-note string｜nil —
    查新 session id → `opencode export <sid>` → 寫
    `.agents/handoff/<seat>.md`（`maduin-handoff-write`，缺則直寫）→
    殺 buffer。**export 先於 kill**。
  - `(maduin-terminal-active-p seat)` → boolean。
  - Buffer 名 `*maduin/{role}-{seat}*`。
  - 純函式（可單元測）：`--buffer-name`、`--choose-backend`、
    `--backend`、`--template`、`--substitute`、`--prompt`、
    `--command-line`、`--parse-session-ids`、`--handoff-note`。
- `harness/maduin.el`：`(require 'maduin-terminal)`；
  `maduin--feature-list` 加 `maduin-terminal`。
- `harness/maduin-test.el`：+9 ERT（tag maduin）。

## 介面

- `maduin-terminal-open` ／ `maduin-terminal-dismiss` ／ `maduin-terminal-active-p`。
- `(maduin-terminal--backend)` → `vterm`｜`term`（`(require 'vterm nil t)`
  探測，無硬依賴）。
- `(maduin-terminal--choose-backend VTERM-AVAILABLE)` → symbol（純，供測試）。
- `(maduin-terminal--parse-session-ids JSON ROOT &optional SINCE EXCLUDE)`
  → ((created . id) ...) 新→舊。

## CLI 驗證（opencode 1.18.15）

- `opencode export [sessionID]` — 有（`opencode --help`）。
- `opencode session list [--format table|json]` — 有；json 回 `id/directory/created`。
- TUI 啟動旗標：`--dir` **非** TUI 合法選項（傳入即打 help 拒絕）—
  以 positional `<root>` 取代 spec 的 `--dir`。`-m`/`--prompt` 合法（`--prompt`
  實測啟動 TUI 並掛起 = 接受）。故 launch = `opencode <root> -m <model> --prompt <template>`。

## 驗證

- `emacs -Q --batch -L harness -l maduin-test
  --eval '(ert-run-tests-batch-and-exit "maduin-test-")'` →
  50/50 過，0 unexpected（41 舊 + 9 新）。
- byte-compile `maduin-terminal.el` 淨（vterm 三函 `declare-function` 靜音）。

## 注意

- session id 擷取：dismiss 時 `session list --format json` 取 root 目錄下
  新於 started-at 且不在 open 時快照（known-ids）的最新 session。
  並行 `opencode run` 同目錄碰撞仍理論可能（取最新）；substrate 階段可接受。
- 測試 handoff 寫入 repo 自身 `.agents/handoff/`（gitignored），
  `unwind-protect` 刪檔自清理，無 /tmp、無一次性測試。
- 未手動 commit（auto-commit watcher 處理）。

# maduin-00r.3 — autonomous session substrate: opencode run + NDJSON parsing

## 改動

- `harness/maduin-session.el` — 重寫為雙 substrate：
  - **autonomous（一次性）substrate**（本任務核心）：
    - `(maduin-session-run workdir model plan)` →
      spawn `opencode run --dir WORKDIR -m MODEL --format json --auto
      --title <handle> PLAN`（`make-process` + `process-filter` 逐行消費
      NDJSON），回 session handle（string）或 nil（opencode 缺／spawn 敗）。
    - `(maduin-session-complete-p sid)` → `completed`｜`running`｜`failed`。
    - `(maduin-session-diff sid)` → `opencode export` 的 `messages[].info.summary.diffs[]`
      攤平為 diff alist list。
    - `(maduin-session-delete sid)` → `opencode session delete`，回 boolean，
      並清 registry／kill process+buffer。
    - `maduin-session-on-complete-hook` — (sid status) 於 sentinel 一次性觸發。
    - NDJSON parser（純，可單元測）：`(maduin-session--parse-line line)`
      → `(:type :session-id :terminal)`，`terminal` 由
      `step_finish.reason`（stop→completed，error→failed）＋
      `tool_use.state.status`（error→failed）判定。
    - **不信 exit code**：permission 拒仍 exit 0 → 完成態只由事件流判定；
      sentinel 無 terminal 事件即 `failed`。
    - registry：`maduin-session--registry` hash（handle → buffer），
      buffer-local 持 status/session-id/pending/done-p。
  - **legacy seat-buffer substrate（compat shims）**：`maduin-session-create`／
    `-kill`／`-list`／`-switch`／`-alive-p`／`--buffer`／`--buffer-name`／
    `--sentinel`／`maduin-session-on-exit-hook` 原樣保留 — pipeline／agent／
    resolver／cockpit／handoff 既有呼叫點不破；.5 dispatch 重建後再移除。
  - 不再掃 RESOLVED_DONE（session.el 內無殘留 text scanning）。
- `harness/test/fake-opencode`（新增，repo 內永久 shim，非 /tmp）：
  emulates `run`（emit NDJSON；`MADUIN_FAKE_MODE=fail` 時 emit tool_use error
  但 exit 0 — 驗證 exit code 不可信）、`export`（emit 單 diff）、`session delete`。
- `harness/maduin-test.el`：+12 ERT（tag maduin）— parser 6、run 集成 2
  （completes／permission-denied）、missing-cli／complete-p-unknown／diff-unknown、
  原 `session-create-kill` 留。

## 介面

- `maduin-session-run`        → handle string｜nil
- `maduin-session-complete-p` → `completed`｜`running`｜`failed`
- `maduin-session-diff`       → diff alist list｜nil
- `maduin-session-delete`     → boolean
- `maduin-session-on-complete-hook` — (sid status)
- `maduin-session--parse-line` → `(:type :session-id :terminal)`（純）

## CLI 驗證（opencode 1.18.15，實測）

- `opencode run [msg] --dir --format json --auto -m --title` — 有；NDJSON 事件
  `sessionID` 於每事件頂層；`step_finish.reason` = stop/tool-calls/error；
  `tool_use.part.state.status` = completed/error（實測探針）。
- `opencode session delete <sid>` — 有。
- `opencode export [sid]` — 有；`messages[].info.summary.diffs[]` 含 patch。

## 驗證

- `emacs -Q --batch -L harness -l maduin-test
  --eval '(ert-run-tests-batch-and-exit "maduin-test-")'` →
  61/61 過，0 unexpected（50 舊 + 12 新）。
- byte-compile `maduin-session.el` 淨，無警告。
- 註：另發現並清除了 2 枚 stale `.elc`（`maduin-bd-bridge.elc`／`maduin-gate.elc`，
  由前任務誤提交），其載入導致 `resolver-start-*` 兩測
  `void-variable opencode-go/deepseek-v4-pro` — 刪後全綠。

## 注意

- `run` 回 handle（自 `--title` 派生）；真 `sessionID` 由 NDJSON 捕獲存於
  buffer，`diff`／`delete` 內部解析 — caller 只持 handle 即可。
- 未手動 commit（auto-commit watcher 處理）。

# maduin-00r.7 — designer (Ramuh): PDD research + design/acceptance + stage

## 改動

- `harness/maduin-designer.el`（新）— Ramuh designer：
  - `(maduin-designer-design task &optional plan)` → session handle｜nil。
    從 `templates/designer-prompt.txt` 建 plan（`{id}/{title}/{desc}` 代入，
    title/desc 經 `maduin-bd-show`），呼叫 `maduin-dispatch-design`。
    designer 擁有 prompt 內容；dispatch 擁有 spawn／concurrency。
  - `(maduin-designer-drop-in seat)` → buffer。委派 `maduin-terminal-open`
    （role `designer`，model 自 config designer 席解析）— Summoner 中途澄清。
  - `(maduin-designer-pending-tasks)` → 缺 `--design` 的 deferred task list。
    `bd query "status=deferred AND type=task"` 後按 design 有無過濾。
  - `(maduin-designer--has-design id)` — `bd show --json` 不曝 design 欄，
    故 parse 人類可讀 `bd show ID` 的 `DESIGN` section header 判有無。
  - 注入縫（defvar fn slot，測試 mock）：`--show-fn`／`--query-fn`／
    `--has-design-fn`／`--dispatch-fn`／`--terminal-open-fn`。
- `harness/maduin-dispatch.el` — `maduin-dispatch--spawn` 增 `&optional plan`
  （`(or plan (maduin-dispatch--plan-for ...))`）；`maduin-dispatch-design` 增
  `&optional plan` 透傳。dispatch 仍掌 claim/seat/cap，designer 供 plan。
- `harness/templates/designer-prompt.txt`（新）— Ramuh 設計 prompt 模板。
- 未 reimplement staging：stage（defer + staged label + design/acceptance）
  由設計 session 內 bd CLI 執行，鏡像 `maduin-gate-stage`（gate 保持
  唯一 deterministic staging API）。

## 介面

- `maduin-designer-design`         → session-id｜nil（&optional plan）
- `maduin-designer-drop-in`        → buffer
- `maduin-designer-pending-tasks`  → list
- `maduin-dispatch-design`         → session-id｜nil（&optional plan）
- `maduin-designer--prompt`/`--template`/`--has-design` — 內部

## 驗證

- `emacs -Q --batch -L harness -l maduin-test
  --eval '(ert-run-tests-batch-and-exit "maduin-test-")'` →
  80/80 過，0 unexpected（73 舊 + 7 新 designer 測）。
- byte-compile `maduin-designer.el` + `maduin-dispatch.el` 淨，無警告。

## 注意

- `bd show --json` 不曝 design/acceptance（--long 亦無）→ 有無 design 以
  human-readable `DESIGN` header 判定，非 JSON 欄。
- 未手動 commit（auto-commit watcher 處理）。
