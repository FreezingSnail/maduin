# Model Implementor Evaluation Report

**Date:** 2026-08-20  
**Benchmark workspace:** sibling repository `../testingground`

## Executive finding

GPT Luna and GPT Terra are the leading implementation options from the measured runs. Both completed the normalizer benchmark correctly on their first implementation pass and passed the harder dependency-planning benchmark, including permanent and independent stress validation. The evidence does not identify a correctness winner between them. Terra's hard-task change was shorter (133 changed lines versus Luna's 162), but line count is only a weak maintainability signal.

GLM-5 completed work after repair loops and was useful as the benchmark designer after a specification revision. Qwen Coder Next passed visible normalizer tests but violated the contract by rejecting valid `collections.abc.Mapping` records; its attempted repair did not update the isolated candidate source.

## Method

Each candidate received the same Bead body, immutable starting revision, dedicated Git worktree, and scope restriction. Candidates could change only the target source file, used Python's standard library, ran the provided verifier, and did not commit. Candidate sources remain unmerged.

Two gates were applied:

1. **Permanent harness:** standard-library conformance tests supplied with each benchmark.
2. **Independent contract gate:** temporary tests derived from the written contract, covering specified behavior not fully exercised by the permanent suite.

This measures functional correctness and specification following. It does not measure latency, throughput, token usage, or cost. Per-model credit/token telemetry was not exposed by the subagent interface; no local usage logs were found under `~/.kiro`; and the available CLI had no usage-report command.

## Benchmark 1 — Record normalizer

`normalize_records(records)` validates and normalizes iterable mapping records without mutation. It exercises generator input, mapping polymorphism, ID/name/email/tag validation, stable tag de-duplication, and indexed `ValueError` messages.

| Model | Candidate Bead | Permanent harness | Independent gate | Result |
| --- | --- | --- | --- | --- |
| GPT Luna | `testingground-4nb` | 7/7 pass | pass | First-pass success |
| GPT Terra | `testingground-vls` | 7/7 pass | pass | First-pass success |
| GLM-5 | `testingground-ilr` | 7/7 pass | failed `Mapping`, then repaired and passed | Success after repair |
| Qwen Coder Next | `testingground-3xb` | 7/7 pass | failed valid `Mapping` input | Unresolved failure |

The independent gate exposed a visible-test gap: Qwen used `isinstance(record, dict)` despite the contract requiring any `collections.abc.Mapping`. GLM-5 initially had the same defect and corrected it after feedback.

## Benchmark 2 — Dependency execution planner

A separate GLM-5 design pass authored `HARD_BENCHMARK.md` for `build_execution_plan(tasks)`. The final contract required layered topological planning; strict, ordered validation; `Mapping` records; one-shot iterables; non-mutation; deterministic mixed `int`/`str` ordering; missing/self dependency handling; and iterative cycle detection.

The first designer draft incorrectly requested Python default ordering across `int`, `str`, and tuple IDs, which is not a total order in Python 3. The design Bead was reopened and revised before candidate work: IDs were narrowed to `int` and `str`, with explicit integer-first ordering and matching validation.

The permanent planner suite contained 31 tests. A shared shell-quoting defect initially prevented both candidates from executing it. The verifier was repaired in shared commit `743af9a`; this infrastructure fault is excluded from candidate ratings.

| Model | Candidate Bead | Permanent harness | Independent stress gate | Result |
| --- | --- | --- | --- | --- |
| GPT Luna | `testingground-bci` | 31/31 pass | pass | First-pass source success |
| GPT Terra | `testingground-bnn` | 31/31 pass | pass | First-pass source success |

The independent planner gate verified custom `Mapping` task records, one-shot dependency iteration, mixed negative/zero integer and string ordering, non-mutation, rejection of boolean/unhashable IDs and unhashable dependency values, and self-dependency precedence over a later missing dependency.

## Ratings

Ratings are provisional, based only on these functional benchmarks.

| Model | Rating | Evidence |
| --- | ---: | --- |
| GPT Terra | 9/10 | First-pass success on both contracts and independent gates; compact hard-task source. |
| GPT Luna | 9/10 | First-pass success on both contracts and independent gates; no correctness separation from Terra. |
| GLM-5 | 7/10 | Correct after repair; initial implementation and initial design contract both needed correction. |
| Qwen Coder Next | 4/10 | Visible-test pass masked a contract violation; attempted repair did not apply. |

## Recommendation

Use **GPT Luna and GPT Terra as the primary implementor pool**. They are tied on measured correctness. Choose between them using operational measurements not available here—availability, latency, pricing, and tool reliability—rather than the current score.

Before choosing one default, run a larger blinded suite including: multi-file compatibility work, intentionally underspecified tasks that require clarification, performance-sensitive algorithms, hidden-regression repairs, and documentation/comment quality. Record wall-clock time, retries, tool failures, tokens, and billed credits using provider-side telemetry, and publish a fixed scoring rubric before dispatch.

## Reproducibility

Shared benchmark artifacts in `../testingground`:

- `9929087` — normalizer benchmark seed.
- `0fd103c` — hard planner contract, unsolved seed, and 31-test verifier.
- `743af9a` — POSIX shell repair for the planner verifier.

Hard-task candidate source deltas relative to the repaired shared baseline were 162 changed lines for Luna and 133 for Terra. This is descriptive, not a quality score. Qwen follow-up `testingground-3xb` remains open because its candidate still rejects valid `Mapping` records.
