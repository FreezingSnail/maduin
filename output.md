# super-harness-c7d.11 — ERT tests for all harness components

## 變更

- `harness/super-harness-test.el` — 新建 ERT 測試套件，20 測試，全標 `:tags '(super-harness)`。

## 覆蓋

| 組件 | 測試 | 驗證 |
|---|---|---|
| config | 5 | 非 nil；crew seats = ant/bat；fleet seats = homer/plato/austen；welfare.handoff-enabled = t；fleet.poll-interval = 30 |
| brain | 3 | write→file 存在；read 回內容；read 缺失→nil；list 回相對路徑（temp dir 綁定 `super-harness-config` brain.path） |
| bd-bridge | 2 | 九函數皆 fboundp；bd CLI 可用時 `super-harness-bd-remember` 存無害 fact，再 `bd forget` 清理（`super-harness-test--bd-forget-matching` 解析 `bd memories --json`）；全程 condition-case 守護，無 bd 亦過 |
| session | 1 | fake CLI（temp shell script `sleep 60`）→ buffer 存在、`alive-p` t、`session-list` 含之、kill→alive-p nil |
| agent | 2 | `agent-status` 無此 seat→nil；`agent-prime` 於 dead session buffer 不 error（綁不存在 CLI 使無 process，走 insert 路徑） |
| handoff | 2 | write/read roundtrip（let 綁 `default-directory` 至 temp dir）；read 缺失→nil |
| pipeline | 2 | `pipeline-status` plist 含六鍵 `:queued :active :completed :blocked :fleet-free :fleet-busy`；`pipeline-fleet-seats` 回 3 |
| cockpit | 2 | `cockpit-show` 造 `*super-harness-cockpit*` buffer；`cockpit-refresh` 不 error（batch 下 `switch-to-buffer` 以 condition-case 守護） |
| main | 1 | `super-harness-mode/start/stop/status/restart/attach/crew/bootstrap` 皆 fboundp |

## 環境安全

- bd 調用（remember/status count）以 condition-case 守護；無 bd 時測試仍過。
- session/agent 用 temp shell script 或不存在 CLI 路徑，不依賴 opencode 真實安裝。
- 不啟動真實進程、不觸發真實 bd 寫入（除可清理之 probe fact）。

## 執行

```bash
# 形式 1：全跑（測試皆 tag super-harness）
emacs -Q --batch -l harness/super-harness-test.el -f ert-run-tests-batch-and-exit

# 形式 2：tag selector
emacs -Q --batch -l harness/super-harness-test.el \
  --eval "(ert-run-tests-batch-and-exit '(tag super-harness))"
```

結果：**20 tests, 20 results as expected, 0 unexpected**（兩種形式皆然，約 3 秒）。
