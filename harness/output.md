# maduin-2rw.2 — reliable land-branch commit+merge+close

## Problem

Completed implementer sessions left tasks `in_progress`: the worker edited
files but no commit/merge/close happened. `maduin-pipeline-land-branch`
committed the worktree and merged the seat branch, but on a missing seat
branch (or other merge failure) it returned nil silently, so
`maduin-dispatch--complete` left the task open with no clear signal.

## Changes

### `harness/maduin-pipeline.el`

- Added function-valued injection seams (defvars) so land-branch is
  testable without a real git repo:
  - `maduin-pipeline--worktree-path-fn`
  - `maduin-pipeline--branch-fn`
  - `maduin-pipeline--main-root-fn`
  - `maduin-pipeline--git-fn`
  - `maduin-pipeline--git-output-fn`
- Hardened `maduin-pipeline-land-branch`:
  - Kept the "nothing staged → return t" path (empty commit still lands).
  - Kept commit-failure detection + logging.
  - **Added** seat-branch verification before merge:
    `git rev-parse --verify <branch>`; when it fails, logs a clear warning
    naming the branch and returns nil (never forces a merge).
  - Kept conflict vs other-merge-failure distinction (`'conflict` vs nil
    with a warning).

### `harness/maduin-dispatch.el`

- No code change needed: verified `maduin-dispatch--complete` calls
  `maduin-dispatch--close-fn` (default `maduin-bd-close`) on `(eq land t)`,
  dispatches the repairer on `'conflict`, and leaves the task open + comments
  on nil. End-to-end close wiring is correct.

### `harness/maduin-test.el`

Added 3 permanent ERT tests (all use the new injection seams; no Python,
no temp files):

- `maduin-test-land-branch-nothing-to-land` → returns `t`.
- `maduin-test-land-branch-conflict` → returns `'conflict` on merge
  conflict output.
- `maduin-test-land-branch-missing-branch` → returns `nil` and logs a
  warning naming the missing branch.

## Validation

`harness/check.sh` → green: 99 tests, 0 unexpected, 0 compile errors,
0 compile warnings (STRICT=1).
