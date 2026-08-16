# maduin-2rw.1 — worktree provisioning: create real git worktrees per seat

## Goal

`maduin-workspace-ensure` produced EMPTY directories under
`harness/workspaces/` instead of real git worktrees. Root cause:
`maduin-bootstrap` creates the per-seat dirs with `make-directory` first, then
`maduin-workspace-ensure` saw `file-exists-p` → true and returned the empty
dir without ever registering a git worktree. Implementer sessions therefore
ran in empty dirs and their git/file ops resolved up to the main repo,
breaking isolation.

## Changes

- `harness/maduin-workspace.el` — rewrote `maduin-workspace-ensure`:
  reuse only a REAL worktree (verified via `git -C <path> rev-parse
  --show-toplevel`); remove a stale empty dir before (re)creating; verify the
  result is a real worktree and return nil otherwise. Added helpers
  `maduin-workspace--remove-stale` and `maduin-workspace--create`.
- `harness/maduin-bd-bridge.el` — added `maduin-bd-worktree-real-p` (checks a
  dir resolves `git -C <dir> rev-parse --show-toplevel` to itself, with
  symlink resolution via `file-truename`). Added `maduin-bd-worktree-add`
  (`git worktree add <path> -b <branch>`, falling back to checking out an
  existing branch). `maduin-bd-worktree-create` now verifies bd's result is a
  real worktree and falls back to `git worktree add` when bd fails or reports
  success on a non-worktree path.
- `.gitignore` — ignore `harness/workspaces/` so per-seat worktree checkouts
  never surface as untracked files in the main repo (bd's `worktree create`
  also skips its per-seat ignore entry once this broad rule exists).
- `harness/maduin-test.el` — added
  `maduin-test-workspace-ensure-real-worktree`: asserts
  `maduin-workspace-ensure` returns a path where `maduin-workspace-exists-p`
  is t and `git -C <path> rev-parse --show-toplevel` resolves inside the
  worktree; cleans up the worktree and branch afterwards.

## Interfaces (unchanged)

- `maduin-workspace-path`, `maduin-workspace-branch`,
  `maduin-workspace-exists-p`, `maduin-workspace-ensure` keep the same
  signatures. Dependents (`maduin-dispatch`, `maduin-pipeline`,
  `maduin-agent`) are unaffected.
- New public helpers: `maduin-bd-worktree-real-p`, `maduin-bd-worktree-add`
  (both in `maduin-bd-bridge.el`).

## Validation

`harness/check.sh`: 96/96 tests pass, 0 unexpected, byte-compile clean, no
warnings. `maduin-test-workspace-ensure-real-worktree` passes.
