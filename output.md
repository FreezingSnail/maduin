# S3: shrink handoff to read/write/cache-path

## Changed

- `harness/maduin-handoff.el` — shrunk to durable cache primitives only:
  - Deleted: `maduin-handoff-request`, `maduin-handoff-wait`,
    `maduin-handoff-restart`, `maduin-handoff-stop-all`,
    `maduin-handoff-marker`, and the now-unused `maduin-handoff--config-get`
    helper.
  - Kept: `maduin-handoff-cache-path`, `maduin-handoff-read`,
    `maduin-handoff-write`.
  - Dropped `(require 'maduin-agent)` and `(require 'maduin-session)`;
    kept `(require 'maduin-config)` (used by `maduin-project-root`).
- `harness/maduin.el` — `maduin-stop` no longer calls
  `maduin-handoff-stop-all` / no `welfare.handoff-timeout` lookup;
  docstring updated. (Required by acceptance: no handoff symbols remain.)
- `harness/maduin-cockpit.el` — `maduin-cockpit-kill` no longer references
  `maduin-handoff-restart`; falls straight to `maduin-agent-kill`.

## Note: S2 precondition not met

Design precondition said S2 (`maduin-zxe.1`) already removed the
`maduin-handoff-stop-all` caller in `maduin-stop` and cockpit's
`maduin-handoff-restart` use. S2 is still OPEN, so those references were
still present. Removed them here (minimal, targeted — required by S3
acceptance "no symbols remain anywhere"). Remaining S2 scope (drop agent
requires, delete attach/kill, dispatch-based cockpit rows, feature-list
trim) is untouched and stays in `maduin-zxe.1`.

## Validation

- `harness/check.sh` → exit 0, 109/109 ERT green, byte-compile clean.
- `harness/maduin-handoff.el` exposes exactly
  `maduin-handoff-cache-path` / `maduin-handoff-read` /
  `maduin-handoff-write`.
- No `maduin-handoff-request|wait|restart|stop-all|marker` symbols remain
  in `harness/` (checked via ripgrep).
- `maduin-test-terminal-handoff-note-write` (dismiss handoff-note flow)
  passes.