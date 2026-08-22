# maduin

maduin is an Emacs-native orchestrator. It wraps
[opencode](https://opencode.ai) and DeepSeek in a self-managing crew
and fleet pipeline for agentic software development.

Designer agents decompose work into tasks. Tasks live in a
[`bd` (beads)](https://github.com/gastownhall/beads) knowledge graph.
Fleet agents poll that graph, claim tasks, implement them, and close
them.

Everything runs inside Emacs. Buffers replace tmux sessions. Elisp
replaces bash. The cockpit is an Emacs dashboard.

maduin manages its own development. It dogfoods itself.

![maduin cockpit demo](screenshots/maduin_cockpit.png)

## How it works

```
concierge  →  intake & prioritize work
designer   →  design, decompose into bd tasks (dependencies tracked)
fleet      →  poll ready tasks → claim → implement → commit (message = record) → close
reviewer   →  per-epic drift-review gate after each wave (APPROVED/DRIFT)
repairer   →  merge-conflict resolution on a diverged seat branch
```

- **Demand-driven orchestration.** `maduin-start` activates the
  dispatchers. It spawns zero sessions. The run-loop polls ready `bd`
  tasks and spawns one ephemeral session per task, up to the fleet
  concurrency cap. Idle means zero running sessions.
- **Ephemeral sessions.** Each session runs one-shot
  `opencode run --format json --dir <worktree>` per task. Each seat
  has an isolated workspace.
- **Review gate after each wave.** When an epic's last child task lands
  and closes, the reviewer (Odin) runs once for that epic, comparing the
  wave's full diff against the epic's design/acceptance. `APPROVED`
  closes the epic. `DRIFT` files a P1 `drift-fix` bead under it. While a
  review is in flight — or any `drift-fix` bead is still open — the fleet
  is held: workers dispatch the rework first and consume no other
  tickets until the gate is clear. `max-retries` bounds re-reviews of a
  repeatedly drifting epic.
- **Model welfare.** Seats are persistent identities with history.
  Sessions are one workday (wake → work → hand off → sleep). Agents
  close their own sessions. There is no `SIGTERM`. Agents receive
  purpose and past laurels. They have a right to refuse: escalate to
  a human instead of accepting a penalty.

## The cockpit and chaplet

`M-x maduin-cockpit-show` opens the cockpit. It displays seats,
status, and pipeline state. It auto-refreshes while visible.

The cockpit embeds the [chaplet](https://github.com/FreezingSnail/chaplet)
inbox in a lower window when chaplet is installed. chaplet is a
magit-style Emacs interface for the `bd` issue tracker. Use it to
browse beads, inspect dependency graphs, and approve or reject staged
work through `transient` menus. Inbox views re-fetch from `bd` on
focus (see `chaplet-auto-refresh`), and the embedded inbox refreshes on
explicit `r` (cockpit refresh) or `i` (inbox) commands, never on the
cockpit timer. Install chaplet from its own repository; maduin uses it
as an optional dependency.

## Requirements

- Emacs 26+
- [`opencode`](https://opencode.ai) on `PATH`
- [`bd`](https://github.com/gastownhall/beads) on `PATH`
- A `bd`-initialized project (`.beads/` directory) for task tracking
- Optional: [chaplet](https://github.com/FreezingSnail/chaplet) for
  the embedded review inbox

The core is elisp-only. There is no external runtime beyond `opencode`,
`bd`, and Emacs.

## Install

```bash
# from the repo root
./harness/install.sh            # wire maduin into Emacs (Doom-aware)
./harness/install.sh --uninstall  # remove the wiring (keeps the repo)
```

The installer appends a managed snippet to your Emacs init
(`~/.config/doom/config.el` for Doom, else `~/.emacs.d/init.el`). It
adds the harness to `load-path`, requires `maduin`, and enables
`maduin-mode`. It also symlinks the opencode agent definitions under
`harness/agents/` into `~/.config/opencode/agent/`.

Restart Emacs, or run `M-x maduin-reload`.

## Usage

| Command | Action |
|---|---|
| `M-x maduin-bootstrap` | First-time setup: create brain/handoff/logs + per-seat workspaces |
| `M-x maduin-start` | Activate dispatchers (spawns 0 sessions) |
| `M-x maduin-stop` | Drain and stop; `C-u` forces a hard stop |
| `M-x maduin-restart` | Hard-stop then start |
| `M-x maduin-status` | Refresh cockpit and show a summary |
| `M-x maduin-cockpit-show` | Open the cockpit dashboard |
| `M-x maduin-cockpit-inbox` | Jump to the embedded chaplet inbox |
| `M-x maduin-concierge` | Feed an idea to the concierge |
| `M-x maduin-concierge-dismiss` | Dismiss the concierge seat |
| `M-x maduin-designer-drop-in` | Start a designer drop-in session |
| `M-x maduin-designer-pending-tasks` | Show pending design tasks |
| `M-x maduin-log-show` | Open the runtime log buffer |
| `M-x maduin-reload` | Unload/reload all modules (edit-then-reload dev loop) |

Keybindings (global, via `maduin-mode`):

| Keys | Action |
|---|---|
| `C-c s s` | status (open/refresh cockpit) |
| `C-c s c` / `C-c s d` | concierge / dismiss |
| `C-c s n` / `C-c s p` | designer drop-in / pending tasks |
| `C-c s l` | log buffer |

## The log

`*maduin-log*` is an append-only record of what the harness is doing.
Open it with `M-x maduin-log-show`, `C-c s l`, or `L` in the cockpit.
Structured lines stay greppable:

```
10:38:36 info  start poll-interval=30 fleet=3
10:38:36 info  pickup task=maduin-42 role=implementer seat=shiva backend=kiro model=gpt-5.6-terra difficulty=high effort=high retry=- handle=maduin-kiro-1
10:38:36 info  finish task=maduin-42 role=implementer seat=shiva status=completed
10:38:36 warn  land task=maduin-42 seat=shiva result=conflict
10:38:36 info  review-gate epic=maduin-7 seat=odin hold=fleet
10:38:36 warn  review-verdict epic=maduin-7 verdict=drift drift-fix=maduin-51 feedback=acceptance 3 unmet
```

Recorded events: `start`/`stop`, `pickup`, `seat-refused`, `spawn-failed`,
`usage-limit`, `finish`, `land`, `close`, `recover`, `fleet-hold`,
`review-gate`, `review-verdict`, `review-abort`, plus every module warning
and error that used to go only to the echo area. `tick` lines (per-poll
ready/rework/held counts) appear at `debug`.

In the log buffer: `q` quit, `c` clear, `l` set level, `G` resume tailing.
`maduin-log-level` (default `info`) sets the threshold,
`maduin-log-echo-level` (default `error`) what also reaches the echo area,
and `maduin-log-max-lines` (default 5000) the retained history. Logging
never signals — a bad log line cannot abort a land, close, or verdict.

## Configuration

Configuration lives in `harness/config.el` as native elisp sexps. There
is no YAML and no parser dependency. The schema (v0.3) defines agent
model + seat mappings. The `crew` section has a runtime-editable `backend`
override: set it to `opencode` or `kiro` to use that provider for every
configured seat, or leave it `nil` (`unset` in the cockpit panel) to preserve
normal per-seat behavior. Effective backend precedence is: explicit crew
override > per-seat override > role backend > `opencode` default. The model
continues to come from the selected effective backend's model mapping.

- **concierge** — `slugineer-planner-concierge`
- **designer** — `slugineer-planner-designer`
- **fleet** — `slugineer-worker` (flash model; `poll-interval`,
  `max-concurrent`, `fallback` for the paid flash bucket). Difficulty routing
  adds these tier keys:

  | Key | Default | Value |
  |---|---|---|
  | `kiro-model-low` | `gpt-5.6-luna` | Kiro model ID for `difficulty:low` |
  | `kiro-model-high` | `gpt-5.6-terra` | Kiro model ID for `difficulty:high` |
  | `kiro-effort-low` | `medium` | Kiro `--effort` value for low |
  | `kiro-effort-high` | `high` | Kiro `--effort` value for high |
  | `effort-low` | unset (`nil`) | OpenCode `--variant` value for low |
  | `effort-high` | unset (`nil`) | OpenCode `--variant` value for high |

  Kiro accepts `low`, `medium`, `high`, `xhigh`, or `max` for `--effort`.
  OpenCode accepts `minimal`, `low`, `medium`, `high`, or `max` for
  `--variant`; both OpenCode values ship unset, preserving the known-good
  flash command line. For Kiro, model precedence is seat tier key > role tier
  key > `kiro-model`. Untagged or unrecognized tiers use the role default.
  A tier never changes the OpenCode model.
- **reviewer** — `slugineer-reviewer` (`max-retries`, `esper`)
- **repairer** — `slugineer-repairer` (`max-retries`, `esper`)

Other sections: `welfare` (handoff timeout, blamelessness),
`workspaces` (path), `harness` (name, version).

### Difficulty tiers and provenance

Ramuh labels every child bead exactly once as `difficulty:low` or
`difficulty:high`; the harness, not the bead, maps that tier to its model and
reasoning effort.

Every landed commit carries these trailers: `Maduin-Model`, `Maduin-Backend`,
`Maduin-Difficulty`, `Maduin-Effort`, `Maduin-Agent`, `Maduin-Seat`,
`Maduin-Task`, `Maduin-Harness`, and `Maduin-Harness-Rev`. Query provenance
with:

```bash
git log --grep '^Maduin-Model: gpt-5.6-terra'
git log --format='%h %(trailers:key=Maduin-Model,valueonly)'
```

Trailers are stamped during land's existing rebase instead of by hooks because
`core.hooksPath` is shared across worktrees and may already belong to another
tool.

## Testing

Single entry point:

```bash
harness/check.sh                     # clean + byte-compile + ERT (407 tests)
harness/check.sh -c                  # compile only
harness/check.sh -k                  # skip clean
harness/check.sh probe probes/<f>.el # + exploratory probe test
harness/check.sh probe probes/probe-cockpit-perf.el # cockpit refresh timing (50 seats)
```

Exit codes: `0` green · `1` compile error · `2` test fail · `3` probe fail ·
`5` byte-compile warnings (`STRICT=1`).

Tests are permanent ERT files co-located with source
(`harness/maduin-test.el`). Exploratory questions go in
`harness/probes/` as `probe-*` tests. Promote them to `maduin-test-*`
when they prove a real invariant.

## Layout

```
harness/
├── maduin*.el        # 20 implementation modules (config, session, async bd, state, …)
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

- **Exit codes lie.** `opencode run` exits 0 even on permission
  rejection. maduin parses NDJSON events (`step_finish.reason`,
  `tool_use.state.status`) for the real completion signal. See the
  session substrate in `maduin-session.el`.
- **Buffers, not tmux.** Each seat is an Emacs buffer named
  `*maduin/{role}-{seat}*`.
- **Shared state only via bd + brain.** Per-seat workspaces are
  isolated. Nothing else touches another seat's tree.
- **The commit message is the record.** Workers describe what they did
  in the commit body; close writes that summary into bd as the close
  reason. No report files are produced in any worktree.
- **Seats sync before they work.** Dispatch brings a seat's branch to
  current `main` before claiming: a fully landed branch is reset to
  `main`, unlanded commits are rebased onto it. Uncommitted changes are
  left alone. A seat whose unlanded work conflicts with `main` is
  refused and the task stays ready for another seat, so divergence is
  found before a session burns on a stale tree.
- **Resolution is rebase-only.** Land fast-forwards `main`; a diverged
  fast-forward (a concurrent land) is re-rebased and retried. Real
  conflicts go to the repairer, which rebases too — merging `main` into
  a seat branch would be replayed away by land.
- **History stays linear, enforced three ways.** `maduin-start` and
  `maduin-bootstrap` harden the shared repo config
  (`merge.ff=only`, `pull.rebase=true`, `commit.cleanup=strip`), which
  backfills onto existing projects since all seat worktrees share one
  `.git`. Agent permissions deny `git merge` / `git pull`. Land then
  asserts `main..<branch>` holds no merge commit before touching `main`;
  a non-linear branch (or an unreadable count) is refused as `conflict`
  and handed to the repairer.
- **One commit per task, not two.** Land no longer adds a contentless
  `task complete (<seat>)` commit on top of the worker's own. A dirty
  tree is folded into the worker's unlanded commit with
  `git commit --amend`; only a branch with nothing unlanded gets a
  fresh commit. Amending is safe — the tip is unlanded and land's
  stamped rebase rewrites it anyway.
- **Startup recovery.** The harness detects tasks left `in_progress`
  by a crashed or quit session on start. It re-dispatches them, so
  `bd ready` re-surfaces orphaned work.
- **The gate is the reviewer, the UI is chaplet.** Auto-close is gated
  by the per-epic drift review, not by a human click. Use chaplet to
  browse beads and to approve (undefer) or reject staged work.
- **Provenance is stamped, not self-reported.** Land records the
  resolved model and effort in commit trailers.

## Inspiration

Adapted from Steve Yegge's Wheelhouse (Emacs-native, ~25k elisp),
re-targeted from Claude Code MAX + Anthropic to opencode + DeepSeek.
