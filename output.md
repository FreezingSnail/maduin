# output.md — super-harness-c7d.10 (super-harness.el: minor mode, commands, keybindings)

## Implemented interface

File: `harness/super-harness.el`

### Minor mode

- `super-harness-mode` — global minor mode, lighter ` SH`.
  Keymap `super-harness-mode-map`:
  - `C-c s s` → `super-harness-status`
  - `C-c s a` → `super-harness-attach`
  - `C-c s c` → `super-harness-crew`

### Interactive commands

- `(super-harness-start)` → void
  Reads config; for each crew seat: `super-harness-agent-spawn`
  seat `crew` model workdir (workdir = `workspaces.path`/SEAT); for
  each fleet seat: spawn + `super-harness-pipeline-start-fleet`;
  then `super-harness-cockpit-show` + `super-harness-cockpit-refresh`;
  message `super-harness started`.

- `(super-harness-stop)` → void
  `(super-harness-handoff-stop-all welfare.handoff-timeout)` then
  `super-harness-session-kill` for every remaining session; message
  `super-harness stopped`.

- `(super-harness-status)` → void
  `super-harness-cockpit-refresh` + summary message with session
  count and `super-harness-cockpit--pipeline-summary`.

- `(super-harness-restart)` → void
  `super-harness-stop` then `super-harness-start`.

- `(super-harness-attach SEAT)` → void (interactive)
  `completing-read` over config seats (crew + fleet), then
  `super-harness-session-switch`.

- `(super-harness-crew WORK)` → void (interactive)
  Prompts for work text, `super-harness-pipeline-dispatch-crew`.

- `(super-harness-bootstrap)` → void
  Creates `.agents/brain`, `.agents/handoff`, `.agents/logs` and
  per-seat workspace dirs; checks `.beads` (hint to run `bd init`
  when absent); message done.

### Helpers

- `(super-harness--config-get KEY [SECTION])` → value | nil
  Looks up KEY in `super-harness-config`; optional SECTION scopes
  lookup, e.g. `(super-harness--config-get 'handoff-timeout 'welfare)`.

- `(super-harness--seats)` → `((SEAT . ROLE) ...)` from config, crew
  then fleet.

- `(super-harness--seat-model SEAT ROLE)` → model string | "default".

- `(super-harness--seat-workdir SEAT)` → expanded workspace path.

### Hooks

- `kill-emacs-hook` — `super-harness-stop` added at load time
  (`add-hook` deduplicates on re-require).

### Requires

`cl-lib`, `super-harness-config`, `super-harness-session`,
`super-harness-agent`, `super-harness-handoff`,
`super-harness-pipeline`, `super-harness-cockpit`. Provides
`super-harness`.

## Validation

- `emacs -Q --batch -l harness/super-harness.el -f batch-byte-compile` → exit 0, no error.
- `(super-harness-bootstrap)` in batch → `bootstrap done`, dirs
  created, `.beads` present (no hint).
- `(super-harness-status)` in batch → 5 seats, no error.
- `(super-harness-start)` in batch → 5 sessions `running` (ant, bat
  crew; homer, plato, austen fleet), cockpit rendered, no error.
- Batch `(super-harness-stop)` blocks ~120s per live session by
  design (`super-harness-handoff-wait` timeout); interactive use is
  the intended path.

## Usage

1. `M-x super-harness-bootstrap` — first-time setup.
2. `M-x super-harness-start` — launch crew + fleet, open cockpit.
3. `C-c s s` / `M-x super-harness-status` — refresh dashboard.
4. `C-c s a` / `M-x super-harness-attach` — jump to an agent buffer.
5. `C-c s c` / `M-x super-harness-crew` — dispatch work to crew.
6. `M-x super-harness-restart` — stop + start.
7. `M-x super-harness-stop` — graceful handoff + shutdown (also runs
   on Emacs exit via `kill-emacs-hook`).
