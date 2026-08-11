# output.md — super-harness-c7d.6 agent.el

## 改
- `harness/super-harness-agent.el` — 实现 agent 生命周期（spawn/prime/kill/status/restart）

## 新增接口

```elisp
(super-harness-agent-spawn seat role model workdir)   ;; → process | nil
  ;; session-create 委托；失败返 nil；创建后自动 prime；返进程

(super-harness-agent-prime seat-name &optional role)  ;; → void
  ;; 模板（crew/fleet-prompt.txt）替换 {name}{seat}{model}
  ;; 追 brain.prime-files 内容（super-harness-brain-read）
  ;; 追 handoff 缓存（.agents/handoff/{seat}.md，优先 handoff-read）
  ;; 追 bd context（super-harness-bd-prime，可用时）
  ;; 进程活→process-send-string；否则插 buffer（禁只读）

(super-harness-agent-kill seat-name)                  ;; → boolean（委托 session-kill）

(super-harness-agent-status seat-name)                ;; → plist
  ;; (:status :task :uptime :model :role)；uptime = (- (float-time) started-at)

(super-harness-agent-restart seat-name)               ;; → process | nil
  ;; 从 buffer-local 读 seat/role/model/workdir，kill 后重 spawn
```

## 其他
- `super-harness-agent-priming-hook` — defvar，prime 后运行，收 seat-name
- requires: cl-lib, super-harness-config, super-harness-session, super-harness-brain；bd-bridge 用 condition-case 守护
- 文件内自推 load-path（本文件所在目录），支持 `emacs -Q --batch -l` 直载
- 辅助私有函数：`super-harness-agent--config-get`、`--template`、`--substitute`、`--handoff`、`--priming-text`

## 验证
- `emacs -Q --batch -L harness -f batch-byte-compile harness/super-harness-agent.el` — 无错无警告
- `emacs -Q --batch -l harness/super-harness-agent.el -f batch-byte-compile` — 无错
- 功能测试（batch）：prime 插模板+brain+bd 上下文于 buffer，替换正确；spawn 生进程；restart kill+重生，status plist 正确；kill 返 t

## 注意
- 模板文件目前仅含 {name} {seat}，无 {model} 占位符；替换逻辑已备，模板增占位符即生效
- session-create 遇 opencode 缺失返 buffer 无进程；spawn 仍返 nil 进程（诚实状态）
