# maduin-d17.1 — auto-detect new epic → dispatch Ramuh decomposition

## Goal

Run-loop (`maduin-dispatch`) detects open epics lacking decomposition and
auto-dispatches a Ramuh design session per epic, respecting the designer
concurrency cap (1 seat). Reuses maduin-designer machinery. Deterministic
trigger is elisp; Ramuh is the only LLM step.

## Changes

- `harness/maduin-bd-bridge.el`
  - `maduin-bd-open-epics` — query open epics (`status=open AND type=epic`).
  - `maduin-bd-epic-children` — query children of an epic (`parent=<id>`).
- `harness/maduin-dispatch.el`
  - New injection seams: `maduin-dispatch--open-epics-fn`,
    `maduin-dispatch--epic-children-fn`, `maduin-dispatch--epic-decompose-fn`
    (default `maduin-designer-decompose-epic`; `declare-function` silences
    the cross-module reference).
  - `maduin-dispatch--undecomposed-epics` — open epics with zero children
    (deterministic, pure elisp).
  - `maduin-dispatch--decompose-epics` — dispatch one Ramuh session per
    undecomposed epic; spawn no-ops at the designer cap via existing
    `maduin-dispatch--spawn` concurrency logic.
  - `maduin-dispatch-run-loop` — now polls ready tasks AND decomposes epics
    each tick.
  - `maduin-dispatch--complete` — designer sessions land the branch but do
    NOT close the task: the epic stays open until its children are
    implemented (closing would falsely complete the epic).
- `harness/maduin-designer.el`
  - `maduin-designer--epic-template` / `maduin-designer--epic-prompt` —
    read `templates/designer-epic-prompt.txt`, substitute {id}/{title}/{desc}.
  - `maduin-designer-decompose-epic` — public entry; dispatches a Ramuh
    session via the existing `maduin-designer--dispatch-fn` seam (designer
    owns the prompt, dispatch owns spawn/concurrency).
- `harness/templates/designer-epic-prompt.txt` (new) — decomposition
  directives: create child tickets under the epic, fill --design +
  --acceptance, defer + label each child "staged"; never close/defer the
  epic itself.
- `harness/maduin-test.el` — ERT coverage:
  - `maduin-test-dispatch-undecomposed-epics` / `-none-open`
  - `maduin-test-dispatch-run-loop-decomposes-epics` (implementer + designer
    sessions both spawn in one tick)
  - `maduin-test-dispatch-designer-completion-does-not-close`
  - `maduin-test-designer-epic-prompt-template` / `-decompose-epic-dispatches`
  - updated functions-exist lists; existing run-loop/full-loop tests bind the
    new seams to no-ops.

## Validation

`harness/check.sh` — 102/102 ERT pass, byte-compile clean (no warnings,
STRICT=1).

## Design notes

- Detection is deterministic: `bd query` only; no LLM in the trigger path.
- Concurrency cap is inherited: `maduin-dispatch-design` →
  `maduin-dispatch--spawn` → `maduin-dispatch--role-cap 'designer` (1 seat).
  When Ramuh is busy, further epics wait for the next tick.
- Once decomposition completes, the epic has children → excluded by
  `maduin-dispatch--undecomposed-epics`; no re-dispatch loop.
