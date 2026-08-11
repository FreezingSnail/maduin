# output.md — super-harness-c7d.9 (cockpit.el: dashboard buffer)

## Implemented interface

File: `harness/super-harness-cockpit.el`

### New public functions

- `(super-harness-cockpit-show)` → buffer
  Creates/switches to `*super-harness-cockpit*`, enables
  `tabulated-list-mode`, installs `super-harness-cockpit-map`, then
  calls `super-harness-cockpit-refresh`. Returns the buffer.

- `(super-harness-cockpit-refresh)` → void (interactive, bound to `r`)
  Sets `tabulated-list-format` to columns `Agent | Role | Status |
  Task | Uptime(s)`. Rows are built from `(super-harness-agent-status
  SEAT)` for every seat in config crew + fleet (via
  `super-harness-pipeline--crew-seats` and
  `super-harness-pipeline-fleet-seats`). Prints the table
  (`tabulated-list-print t`), then appends a pipeline summary line
  from `(super-harness-pipeline-status)`:
  `queued N | active N | completed N | blocked N | fleet-free N | fleet-busy N`.

- `(super-harness-cockpit-attach)` → void (interactive, bound to `RET`)
  Reads the row id (`tabulated-list-get-id`) and calls
  `super-harness-session-switch`. Errors when no row under point.

- `(super-harness-cockpit-kill)` → void (interactive, bound to `k`)
  Reads the row id; when `super-harness-handoff-restart` is loaded
  uses it, else falls back to `super-harness-agent-kill`.

### Keymap

`super-harness-cockpit-map` (sparse keymap, parent
`tabulated-list-mode-map`, installed in `super-harness-cockpit-show`
via `use-local-map`):

- `RET` → `super-harness-cockpit-attach`
- `r` → `super-harness-cockpit-refresh`
- `q` → `quit-window`
- `k` → `super-harness-cockpit-kill`

### Notes

- Requires `cl-lib`, `tabulated-list`, `super-harness-session`,
  `super-harness-agent`, `super-harness-pipeline`,
  `super-harness-config`; `super-harness-handoff` guarded by
  `condition-case`.
- Seat with no live session renders Status `dead`, Task `—`,
  Uptime `—`.
- Pipeline summary appended after the table inside
  `let ((inhibit-read-only t))` because `tabulated-list-mode` buffers
  are read-only.

## Validation

- `emacs -Q --batch -l harness/super-harness-cockpit.el -f batch-byte-compile` → exit 0
- `super-harness-cockpit-show` in batch → creates `*super-harness-cockpit*`
  in `tabulated-list-mode`, renders 5 seats (ant, bat = crew; homer,
  plato, austen = fleet) plus pipeline summary line, no error.
