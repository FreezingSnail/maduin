# maduin-d17.5 — review node: run on epic completion, not batch-N

## What changed

1. **`harness/maduin-review.el`** — batched drift-review → per-epic completion review:
   - **Deprecated** the batch checkpoint (`:start-sha`/`:landed`), `maduin-review--mark-start`, `maduin-review--note-land`, the batch diff, `maduin-review--landed-context`, and the `batch-size` config trigger.
   - **New per-epic trigger** `maduin-review--maybe-review-epic`: after a task lands+closes, resolve its parent epic; when ALL children of that epic are closed, run Odin once for THAT epic.
   - **New per-epic diff scope**: `maduin-review--epic-starts` alist records the pre-land main SHA (`HEAD~1`) at the epic's first child land; later lands keep the original start so `maduin-review--epic-diff` returns the epic's full change set since its tasks began (`git diff START..HEAD`). Falls back to `HEAD~1` (last land) with a warning if the in-memory start is missing after a pipeline restart.
   - **New completion check** `maduin-review--epic-children-closed-p`: every child `parent=<epic>` is closed; an epic with zero children is NOT complete.
   - **Goal context** = the epic's `--design`/`--acceptance` (`maduin-review--design-acceptance`, parsed from `bd show`).
   - **Verdict semantics** (plan text updated to "goal met vs goal not met"):
     - `APPROVED` → goal met → epic closed (`bd close <epic> --reason "review gate: goal met (Odin approved)"`), recorded start dropped.
     - `DRIFT` → goal not met → drift-fix task created under the epic + comments; epic stays open, start preserved so the next gate sees the full change set.
     - `error` → comment on the epic, stays open (never silent-fail).
   - `maduin-review-gate` now requires `EPIC-ID` (the review subject).

2. **`harness/maduin-pipeline.el`** — fleet sentinel now calls `maduin-review--maybe-review-epic task` after closing a landed task (replaces the `note-land`/batch-full gate).

3. **`harness/maduin-bd-bridge.el`** — `maduin-bd-show` plist now includes `:parent` (from `bd show --json`), needed to resolve a task's epic.

4. **`harness/config.el`** — removed `(batch-size . 3)` from the reviewer section.

## Validation

- `harness/check.sh`: 107/107 tests passed, exit 0.
- Tests updated/replaced: children-closed detection, per-epic start recorded once, epic diff (recorded start + fallback), gate-approved closes epic, gate-drift creates drift-fix and keeps epic open, gate disabled, maybe-review complete / not-complete / no-parent.
