# maduin-6ab.2 — close path: write output.md to seat worktree, not main cwd

- `harness/maduin-bd-bridge.el`:
  - `maduin-bd-close` now takes `&optional DIR` (seat worktree / per-task dir); output file resolved via new `maduin-bd-close-path` under DIR, default `default-directory`. Root `output.md` never clobbered.
  - Close file is ALWAYS written (empty when OUTPUT nil) so `bd close --reason-file` always exists.
  - docstring: `maduin-bd-close-file` resolved under close dir, never main repo root.
- `harness/maduin-dispatch.el`: `maduin-dispatch--close-fn` seam signature `(task output &optional dir)`; `maduin-dispatch--complete` threads `(maduin-dispatch--workdir-fn seat)`.
- `harness/maduin-pipeline.el`: poll sentinel close call threads `(maduin-pipeline--worktree-path-fn seat-name)`.
- `harness/maduin-repairer.el`: close passes `(maduin-workspace-path seat-name)`.
- `harness/maduin-test.el`: new ERT — `maduin-test-bd-close-path`, `maduin-test-bd-close-writes-to-worktree-not-root`, `maduin-test-bd-close-default-dir-fallback`; close-fn mocks updated to 3-arg.
- `harness/check.sh`: 119 tests, 119 passed, compile clean, exit 0.

# maduin-6ab.5 — cleanup: titan worktree synthetic commit (maduin-udj.2)

## What changed

- Investigated `titan` branch junk commit `1490d22` ("maduin-udj.2: blocked — issue not found in beads DB"). Verified it only added an `output.md` note — a worker fabricated a nonexistent issue id. No source/elisp changes.
- Reset the `titan` branch (worktree `harness/workspaces/titan`) to `main` (`665f771`), discarding the junk commit:
  - `git -C harness/workspaces/titan reset --hard main`
- Confirmed other worktrees (alexander, ifrit, ramuh, shiva) and the main checkout source are untouched.
- Branch `titan` skipped for merge.

## Validation

- `git -C harness/workspaces/titan log --oneline -3` → tip is `665f771` (no longer `1490d22`).
- `git -C harness/workspaces/titan status` → clean, `On branch titan`.

## maduin-6ab.4 — startup recovery: re-dispatch orphaned in_progress tasks

- `harness/maduin-bd-bridge.el`: added `maduin-bd-in-progress-tasks` — query `status=in_progress AND type=task`.
- `harness/maduin-dispatch.el`: added `maduin-dispatch--in-progress-fn` seam (default → bridge query); `maduin-dispatch--orphaned-tasks` (in_progress minus active-session registry); `maduin-dispatch--recover`; run-loop now recovers each tick; `maduin-dispatch-start` runs one immediate recovery pass.
- `harness/maduin-test.el`: new ERT `maduin-test-dispatch-orphaned-tasks`, `maduin-test-dispatch-recover-redispatches-orphans`; isolated 5 existing tests from real bd in_progress state (`--in-progress-fn` nil) so suite order doesn't leak claimed tasks into run-loop/main-start tests.
- `harness/probes/probe-recover.el`: exploratory probe (run-loop ready-path spawn).
- `harness/check.sh`: 116 tests, 116 passed, compile clean, exit 0.

## maduin-6ab.1 — land-branch: always merge even when worker pre-committed

- `harness/maduin-pipeline.el` (`maduin-pipeline-land-branch`): removed the "nothing staged → t" short-circuit (`git diff --cached --quiet`). Now always `git add -A` + commit (exit 1 with "nothing to commit" treated as success, not failure), then skip the merge ONLY when the seat branch (worktree HEAD) is already an ancestor of main (`git merge-base --is-ancestor HEAD main`); otherwise verify the seat branch exists and `git merge --no-ff`.
- `harness/maduin-test.el`: replaced `maduin-test-land-branch-nothing-to-land` with `maduin-test-land-branch-already-ancestor` (merge must NOT run when already ancestor) and `maduin-test-land-branch-nothing-to-commit-still-merges` (pre-committed worker → nothing-to-commit → still merges, returns t); conflict/missing-branch tests updated to the new is-ancestor gate.
- `harness/check.sh`: 116 tests, 116 passed, compile clean, exit 0.

## maduin-6ab.3 — cockpit: auto-refresh + dispatch-aware pipeline summary

- `harness/maduin-cockpit.el`: added auto-refresh timer (`maduin-cockpit-refresh-interval` default 5s, `maduin-cockpit--timer`); `maduin-cockpit-show` starts it and registers buffer-local `kill-buffer-hook` → `maduin-cockpit--stop-timer`; `maduin-cockpit--auto-refresh` self-cancels when the cockpit buffer is gone or no longer visible (batch/`q` safe). Manual `r` refresh unchanged.
- Fleet counts in the pipeline summary already read `maduin-dispatch--active` (via `maduin-pipeline--fleet-busy-count`, migrated in earlier epic work) — verified and locked with a new ERT test.
- `harness/maduin-test.el`: new ERT `maduin-test-cockpit-refresh-interval-bound`, `maduin-test-cockpit-timer-start-stop` (idempotent start, clean stop), `maduin-test-cockpit-auto-refresh-cancels-when-hidden`, `maduin-test-pipeline-fleet-busy-dispatch` (dispatch-registry count, not legacy seat buffers).
- `harness/check.sh`: 116 tests, 116 passed, compile clean, exit 0.
