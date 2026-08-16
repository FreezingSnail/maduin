# maduin-d17.3 — concierge: Alexander creates epic + design doc (human-in-loop)

## Goal

Concierge (Alexander) no longer hashes ideas into HIGH-LEVEL deferred task
groups. New flow: capture idea → create epic → **write the design doc on the
epic** (`bd update <epic> --design`) during the interactive conversation.
Ramuh owns decomposition. Report epic id on done.

## Changes

- `harness/templates/concierge-prompt.txt` — rewrote role prompt:
  capture idea → `bd create --type epic` → `bd update <epic-id> --design`
  (goal, approach, components & interfaces, data shapes, error handling,
  testing strategy) → iterate with Summoner → report epic id. Removed
  HIGH-LEVEL task hashing / `--defer` / "Do not design". Added
  "Do not decompose" (Ramuh owns task breakdown).
- `harness/agents/slugineer-planner-concierge.md` — matched: description
  frontmatter, title, Role Mandate (steps 1–4 now end in design doc write),
  Boundaries (NEVER decompose / create child tickets / `--defer` / fill
  `--acceptance`), Output Contract (`epic: <id>` / `design: written` /
  `handoff: bd show <epic-id>`).
- `harness/maduin-concierge.el` — commentary + docstrings updated to match:
  concierge writes the epic design doc in-TUI; decomposition is Ramuh's job.
- `harness/maduin-test.el` — `maduin-test-concierge-prompt-template`
  now asserts `--design`, `design doc`, `Do not decompose`, `Do not
  implement`; dropped `HIGH-LEVEL` / `--defer` / `Do not design`.
  Full-loop test comment updated (deferred task is Ramuh's, not concierge's).

## Validation

`harness/check.sh`: 95/95 tests pass, 0 unexpected, no warnings. Byte-compile
clean.

## No epic created

This task updates concierge role artifacts, it is not itself a concierge
session — no Summoner idea was provided, so no epic was created (that would
be inventing work). Epic id reporting lives in the concierge output contract
for live sessions.

## Unblocked

`maduin-d17.1` (auto-detect new epic → dispatch Ramuh decomposition) was
blocked on this task; can proceed.
