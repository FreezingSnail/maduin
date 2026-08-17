# maduin

An Emacs-native orchestrator that wraps [opencode](https://opencode.ai) +
DeepSeek into a self-managing crew/fleet pipeline for agentic software
development.

Crew agents (designers) decompose work into tasks tracked in a [`bd`
(beads)](https://github.com/gastownhall/beads) knowledge graph. Fleet agents
(implementers) poll that graph, claim tasks, implement them, and close them.
Everything runs inside Emacs — buffers replace tmux sessions, elisp replaces
bash, and the cockpit is an Emacs dashboard.

maduin dogfoods itself: maduin's own development is managed by maduin.

## How it works

```
concierge  →  intake & prioritize work
designer   →  design, decompose into bd tasks (dependencies tracked)
fleet      →  poll ready tasks → claim → implement → write output.md into seat worktree → close
reviewer   →  batched drift-review gate (approve/reject)
repairer   →  drift-fix on rejected review output
```

- **Demand-driven orchestration.** `maduin-start` activates dispatchers but
  spawns zero sessions. The run-loop polls ready `bd` tasks and spawns an
  ephemeral implementer session per task, up to the fleet concurrency cap.
  Idle means zero running sessions.
- **Ephemeral sessions** run one-shot `opencode run --format json --dir
  <worktree>` per task, with per-seat workspace isolation.
- **Review gate** blocks auto-close until a batched drift-review passes;
  failures route to the repairer (retry up to `max-retries`).
- **Model welfare.** Seats are persistent identities with history; sessions
  are one "workday" (wake → work → hand off → sleep). Agents close their own
  sessions (no `SIGTERM`), are primed with purpose and past laurels, and have
  a "right to refuse" — escalate to human instead of being penalized.

## Requirements

- Emacs 26+
- [`opencode`](https://opencode.ai) on `PATH`
- [`bd`](https://github.com/gastownhall/beads) on `PATH`
- A `bd`-initialized project (`.beads/` directory) for task tracking

The core is elisp-only: no external runtime beyond `opencode`, `bd`, and Emacs.

## Install

```bash
# from the repo root
./harness/install.sh            # wire maduin into Emacs (Doom-aware)
./harness/install.sh --uninstall  # remove the wiring (keeps the repo)
```

The installer appends a managed snippet to your Emacs init
(`~/.config/doom/config.el` if Doom is detected, else `~/.emacs.d/init.el`)
that adds the harness to `load-path`, requires `maduin`, and enables
`maduin-mode`. It also symlinks the opencode agent definitions under
`harness/agents/` into `~/.config/opencode/agent/`.

Restart Emacs (or run `M-x maduin-reload`).

## Usage

| Command | Action |
|---|---|
| `M-x maduin-bootstrap` | First-time setup: create brain/handoff/logs + per-seat workspaces |
| `M-x maduin-start` | Activate dispatchers (demand-driven; spawns 0 sessions) |
| `M-x maduin-stop` | Gracefully hand off and tear down any live sessions |
| `M-x maduin-restart` | Stop then start |
| `M-x maduin-status` | Refresh the cockpit and show a summary (auto-refreshes while visible) |
| `M-x maduin-attach` | Switch to a seat's session buffer |
| `M-x maduin-reload` | Unload/reload all modules (edit-then-reload dev loop) |

Keybindings (global, via `maduin-mode`):

| Keys | Action |
|---|---|
| `C-c s s` | status |
| `C-c s a` | attach |
| `C-c s c` / `C-c s d` | concierge / dismiss |
| `C-c s n` / `C-c s p` | designer drop-in / pending tasks |
| `C-c s g a` / `C-c s g r` / `C-c s g l` | gate approve / reject / staged list |

## Configuration

Configuration lives in `harness/config.el` as native elisp sexps (no YAML, no
parser dependency). The schema (v0.3) defines agent model + seat mappings:

- **concierge** — `slugineer-planner-concierge`
- **designer** — `slugineer-planner-designer`
- **fleet** — `slugineer-worker` (flash model; `poll-interval`, `max-concurrent`)
- **reviewer** — `slugineer-reviewer` (`batch-size`, `max-retries`)
- **repairer** — `slugineer-repairer`

Other sections: `brain` (path + prime files), `welfare` (handoff timeout,
blamelessness), `workspaces` (path, `land-on-stop`), `pipeline`
(`review-required`, `auto-close-epic`).

## Testing

Single entry point:

```bash
harness/check.sh                     # clean + byte-compile + ERT (119 tests)
harness/check.sh -c                  # compile only
harness/check.sh -k                  # skip clean
harness/check.sh probe probes/<f>.el # + exploratory probe test
```

Exit codes: `0` green · `1` compile error · `2` test fail · `3` probe fail ·
`5` byte-compile warnings (`STRICT=1`).

Tests are permanent ERT files co-located with source
(`harness/maduin-test.el`). Exploratory questions go in `harness/probes/` as
`probe-*` tests and are promoted to `maduin-test-*` when they prove a real
invariant.

## Layout

```
harness/
├── maduin*.el        # 19 modules (config, session, agent, pipeline, …)
├── maduin-test.el    # ERT test suite (permanent gate)
├── check.sh          # compile + test loop
├── install.sh        # Emacs wiring + agent symlinks
├── agents/           # opencode agent definitions (symlinked on install)
├── templates/        # prompt templates (crew, fleet, concierge, designer)
├── probes/           # exploratory ERT tests
└── workspaces/       # per-seat isolated worktrees (created on bootstrap)

.agents/
├── brain/            # markdown knowledge (architecture.md, conventions.md)
├── planning/maduin/  # design docs
└── handoff/          # per-seat handoff caches (runtime)

.beads/               # bd knowledge graph (task tracking)
```

## Key design notes

- **Exit codes lie.** `opencode run` exits 0 even on permission rejection.
  maduin parses NDJSON events (`step_finish.reason`, `tool_use.state.status`)
  for the real completion signal (see the session substrate in `maduin-session.el`).
- **Buffers, not tmux.** Each seat is an Emacs buffer named
  `*maduin/{role}-{seat}*`.
- **Shared state only via bd + brain.** Per-seat workspaces are isolated;
  nothing else touches another seat's tree.
- **Close writes to the seat worktree.** Task summaries (`output.md`) land in
  the task's own worktree, never the main repo root.
- **Startup recovery.** Tasks left `in_progress` by a crashed/quit session are
  detected on start and re-dispatched, so `bd ready` re-surfaces orphaned work.

## Inspiration

Adapted from Steve Yegge's Wheelhouse (Emacs-native, ~25k elisp), re-targeted
from Claude Code MAX + Anthropic to opencode + DeepSeek.
