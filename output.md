# Spike: opencode session substrate (run vs serve vs acp)

opencode version: **1.18.15** · model probed: `opencode-go/deepseek-v4-pro`

## 1. `opencode run` — one-shot, best fit for ephemeral tasks

```
opencode run [message..]
  --model, -m      provider/model
  --agent          agent (e.g. slugineer)
  --dir            directory to run in (PER-SESSION cwd → worktree isolation) ★
  --format         default | json   (json = raw NDJSON events)
  --file, -f       attach file(s) to message
  --title          session title
  --auto           auto-approve permissions not explicitly denied
  --variant        model reasoning effort (high/max/minimal)
  --attach <url>   attach to running `serve` (avoids MCP cold boot)
  --command        run a command, message = args
  --continue/-c, --session/-s, --fork, --share, --thinking, -i interactive
```

Probe (works, exit 0):
```
$ opencode run "say hi" --format json
{"type":"step_start",...,"sessionID":"ses_...","part":{"type":"step-start"}}
{"type":"text",...,"part":{"type":"text","text":"Hi."}}
{"type":"step_finish",...,"part":{"reason":"stop","tokens":{...},"cost":...}}
```

File-edit probe (`--auto`) emits `tool_use` parts with full input/output:
```
{"type":"tool_use","part":{"type":"tool","tool":"write","state":{"status":"completed",
  "input":{"filePath":"...","content":"hello-world"},"output":"Wrote file successfully."}}}
```

### Exit code is NOT a success signal
Without `--auto`, a permission-gated edit is **auto-rejected but still exits 0**:
```
! permission requested: bash (...); auto-rejecting
{"type":"tool_use","part":{"state":{"status":"error","error":"The user rejected permission..."}}}
EXIT: 0
```
→ Must parse events (`step_finish.reason`, `tool_use.state.status`) for success/failure, never trust `$?`.

## 2. `opencode serve` — headless HTTP server (full session lifecycle)

```
opencode serve [--port] [--hostname] [--cors] [--mdns]
  --port 0 = random   (auth: OPENCODE_SERVER_PASSWORD / OPENCODE_SERVER_USERNAME)
```
No `--cwd` flag — cwd fixed at server startup. OpenAPI spec at `GET /doc`.

Key endpoints (verified live):
```
GET  /global/health                     → {"healthy":true,"version":"1.18.15"}
POST /session                           → Session {id, directory, title,...}
POST /session/:id/message               → {info:{finish:"stop"}, parts:[...]}  (synchronous, waits)
GET  /session/:id/diff                  → FileDiff[]  (structured, review-before-land)
DELETE /session/:id                     → true (destroy)
GET  /session/:id/message               → {info, parts}[]
POST /session/:id/abort                 → abort running session
POST /session/:id/fork, /revert, /permissions/:pid
GET  /event (SSE) · GET /session (list) · GET /session/status
```

Live session create + message:
```
$ curl -s -X POST localhost:4199/session -d '{"title":"probe"}'
{"id":"ses_...","directory":"/Users/connorfranc/code/super-harness",...}
$ curl -s -X POST localhost:4199/session/ses_.../message \
    -d '{"parts":[{"type":"text","text":"say hi"}],
         "model":{"providerID":"opencode-go","modelID":"deepseek-v4-pro"}}'
{"info":{"finish":"stop",...,"cost":0.000089204},"parts":[{"type":"text","text":"Hi."},...]}
```

## 3. `opencode acp` — Agent Client Protocol (JSON-RPC over stdio)

```
opencode acp [--cwd <dir>] [--port] [--hostname] [--cors] [--mdns]
```
Has `--cwd` flag. Communicates JSON-RPC 2.0 via stdin/stdout (nd-JSON) — or over HTTP/SSE with `--port`.
Designed for **editor integration** (Zed, JetBrains, Neovim). Session lifecycle is protocol methods
(`session/new`, `session/load`, `session/prompt`, `session/cancel`, permission negotiation `session/request_permission`).
Full feature parity with TUI (tools, MCP, AGENTS.md, permissions). Editor-oriented — not a task-orchestrator surface.

## 4. `opencode session` / `opencode export`

```
opencode session list [--format table|json] [--max-count/-n]
opencode session delete <sessionID>
opencode export [sessionID] [--sanitize]
```

`export` = full structured JSON, includes **per-message diffs with unified patches**:
```
"info": {"summary": {"additions":1,"deletions":0,"files":1}, ...}
"messages": [{"info": {"summary": {"diffs": [
  {"file":"probe.txt","patch":"--- probe.txt\n+++ probe.txt\n@@ -0,0 +1 @@\n+hello-world\n",
   "additions":1,"deletions":0,"status":"added"}]}}, "parts":[...]}]
```

## Key question answers

| Question | Answer |
|---|---|
| Per-session working dir (worktree isolation)? | **YES** — `run --dir <path>`. `acp --cwd`. `serve` fixed dir; for warm server + isolation use `run --attach <url> --dir <worktree>`, or one serve per worktree. |
| Structured completion signal? | `run --format json` NDJSON (`step_finish.reason` = stop/tool-calls/error; `tool_use.state.status`). `serve` `POST /message` → `info.finish`. **Exit code unreliable** (0 on rejection). |
| Structured diffs for review-before-land? | **YES** — `export` → per-message `diffs[]` w/ unified `patch`; `serve` `GET /session/:id/diff` → `FileDiff[]`. Output is NOT free-text-only. |
| Minimal invocation? | See below. |

## Minimal invocation: "run plan in dir X, model M, give result + diffs"

```bash
# spawn-on-demand, kill after (no persistent server)
opencode run --dir "$WORKTREE" -m opencode-go/deepseek-v4-pro \
    --agent slugineer --format json --auto "$PLAN" > events.ndjson
# structured result: parse events.ndjson for step_finish.reason + tool_use
# structured diffs:
opencode export "$SESSION_ID"   # per-message diffs[] with patches
# cleanup:
opencode session delete "$SESSION_ID"
```

## Recommendation

**Use `opencode run` (one-shot, `--format json`, `--dir` for worktree isolation) as the primary substrate**
for ephemeral task-scoped sessions. Matches "spawn → context-complete input → kill" exactly; no server to
manage, per-session cwd, NDJSON events + `export` give structured result & diffs.

**Upgrade to `opencode serve` when** you want a warm pooled backend (avoid per-task MCP/LSP cold boot) or
need synchronous `POST /session/:id/message` + `GET /session/:id/diff` in-process: run one `serve` per
worktree (or `run --attach <serve> --dir <worktree>` for isolation against a shared warm server).

**`acp` only** if the harness already speaks the Agent Client Protocol (editor-class clients). A task
orchestrator does not need it.

**Caveat:** exit code is not a completion/quality signal — always parse JSON events.
