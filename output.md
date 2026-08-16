# maduin-d17.2 — Ramuh: design doc → rich deferred tickets w/ impl instructions

## What changed

1. **`harness/templates/designer-epic-prompt.txt`** — rewritten decomposition prompt for Ramuh:
   - Instructs Ramuh to FIRST read the epic's design doc (`bd show {id}` → DESIGN section, written by Alexander) as source of truth.
   - Every child ticket MUST be RICH: detailed description with concrete implementation instructions (files, interfaces, approach) written for an implementer who has NOT read the design doc; per-ticket `--design`, `--acceptance`, `--deps`.
   - Every deferred child MUST carry the `staged` label (create with `--labels staged` + defer).
   - Retained: research/spike unknowns, native test framework, permanent co-located tests, do not implement, do not close/defer epic.

2. **`harness/templates/designer-prompt.txt`** — single-task designer prompt now requires the same richness for any decomposed sub-tasks: detailed description w/ impl instructions (files, interfaces, approach), `--design`/`--acceptance`/`--deps` per sub-task, every deferred sub-task MUST carry `staged` label.

3. **`harness/maduin-test.el`** — `maduin-test-designer-epic-prompt-template` asserts the new directives: `--acceptance`, `--deps`, "implementation instructions", "files", "interfaces", "bd show".

## Validation

- `harness/check.sh`: 102/102 tests passed, exit 0.

## Notes

- No implementation performed (designer semantics only — prompt templates + tests).
- Existing dispatch/decompose wiring (`maduin-dispatch--epic-decompose-fn`, `maduin-designer-decompose-epic`) unchanged; it consumes the updated template via `maduin-designer--epic-prompt`.
