# maduin-v4x.1 — cockpit-face.el: theme-adaptive cockpit faces (pill + chip palette)

## What Changed

New module `harness/maduin-cockpit-face.el` — single source of truth for
cockpit faces, mirroring `chaplet-face.el` (found at
`/Users/connorfranc/code/chaplet/chaplet-face.el`). Zero external deps
(beyond built-in `color`); batch-safe.

Components (all per task design):

- `maduin-cockpit-state-face (status)` → face symbol for `dead idle
  working running repairing`, `nil` for unknown statuses.
- `maduin-cockpit-state-color (status)` → foreground color string for
  known statuses (falls back to dark-palette color when the face is
  unset, e.g. batch), `nil` for unknown.
- `maduin-cockpit-chip-face (stat-key)` → face for `queued active
  completed blocked fleet-free fleet-busy`.
- `maduin-cockpit-face-setup ()` — applies palette, registers
  `after-load-theme-hook` (idempotent). Called once at module load.
- `maduin-cockpit-face-adapt ()` — recomputes palette for current theme
  via `face-spec-set`, never signals (`condition-case`), logs failures.
  Scheduled via idle timer on theme change (`maduin-cockpit-face-adapt-idle`).

Palette: `maduin-cockpit-face--palette` keyed `(dark (face . color) ...)
(light ...)`. Pill faces (all status + chip faces) specify `:box t` with a
dim background via `color-mix` into the `default` background
(`maduin-cockpit-face--dim-background`), guarded for missing `color-mix`.

## Integration

- `check.sh` FILES: `maduin-cockpit-face.el` inserted before
  `maduin-cockpit.el`.
- `maduin.el`: `(require 'maduin-cockpit-face)` added; feature listed in
  `maduin--feature-list` for reload ordering.
- No changes to `maduin-cockpit.el` render logic (per design: only add
  module + registration).

## Tests

New `;;; 8b. cockpit-face` section in `harness/maduin-test.el` (6 ERT
tests, permanent, native ERT):

1. state-face known statuses are `facep`, unknown/nil return nil
2. state-color non-empty string per known status, nil for unknown
3. chip-face covers all 6 pipeline stats
4. `face-setup` creates all pill faces
5. `face-adapt` runs without error under `--batch`
6. pill faces carry `:box t` when a graphic display is available
   (skips in batch, per acceptance criterion)

## Validation

`harness/check.sh` → exit 0 green: byte-compile clean (STRICT=1, no
warnings), 113/113 ERT tests passed, 0 unexpected.