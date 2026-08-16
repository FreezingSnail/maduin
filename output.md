# maduin-764: remove maduin-gate.el (superseded by chaplet review UI)

Decided in maduin-d17.4: chaplet (separate repo) provides the review UI;
maduin-gate.el is redundant. Removed the elisp approval gate. The consume
path for approved work is `bd ready` (unchanged).

## Changes

- **deleted** `harness/maduin-gate.el` — whole file (stage/approve/reject/approve-epic + "staged" label logic).
- **harness/maduin.el**
  - removed `(require 'maduin-gate)`
  - removed keybindings `C-c s g a` (approve), `C-c s g r` (reject), `C-c s g l` (staged-list)
  - removed `maduin-gate` from `maduin--feature-list` (dev reload order)
- **harness/maduin-test.el**
  - removed `(require 'maduin-gate)`
  - deleted gate ERT tests: `maduin-test-gate-functions-exist`,
    `maduin-test-gate-stage-approve-list`, `maduin-test-gate-reject-keeps-staged`,
    `maduin-test-gate-approve-epic`, and the gate-only helper `maduin-test--gate-scratch`
    (kept `maduin-test--bd-delete`, still used by the full-loop test)
  - `maduin-test-main-interactive-commands`: dropped the 3 gate commands
  - `maduin-test-main-keymap-bindings`: dropped the 3 `C-c s g *` bindings
  - `maduin-test-full-loop-epic-to-close`: staged/approved via gate now consumes
    via `bd ready` directly — `maduin-bd-update-design-acceptance` (design fill)
    then `maduin-bd-undefer` (approve) then asserts presence in `maduin-bd-ready-tasks`
- **harness/maduin-designer.el** — updated Commentary: staging performed via bd CLI
  (defer + staged label), review UI in chaplet, no longer mirrors `maduin-gate-stage`
- **harness/check.sh** — removed `maduin-gate.el` from compile FILES list

## Validation

`harness/check.sh` → **exit 0**: 92/92 ERT tests passed, byte-compile clean
(no warnings).

Acceptance check: `maduin.el` loads without `maduin-gate`; no `maduin-gate-*`
symbols remain in the repo (`grep -rn "maduin-gate" harness/` → no matches).
