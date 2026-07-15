---
spec_type: task
id: ARLO-TASK-SELECTABLE-IMPLEMENTER
status: draft
owners: [Chris Robertson]
depends_on: []
parent_feature: ARLO-FEAT-OUTER-LOOP
fit_check: passed
complexity:
  total: 2
  band: trivial
  drivers: [surface_span]
  scored_on: 2026-07-15
---

# Frame

## TL;DR

Allow operators to select Claude or Codex as the implementation harness and independently choose its model and effort.

## Parent feature

ARLO-FEAT-OUTER-LOOP.

# Substance

## Repro or Given/When/Then

**Given** the current script, **when** an outer-loop or review-fix implementation pass runs, **then** it always invokes Claude with script-selected cycle defaults.

**Given** the updated script, **when** the operator passes `--implementer claude|codex`, `--implementer-model MODEL`, and/or `--implementer-effort LEVEL`, **then** all outer-loop and review-fix implementation passes use the selected harness and forward non-empty model and effort selections through that CLI's native arguments.

**Given** no implementer switches, **when** implementation runs, **then** behavior remains backward-compatible: Claude is selected and the current outer-loop and cycle-specific Claude model defaults remain in effect.

## Affected surface

- `babysit-with-review.sh` argument parsing, usage, startup log, and implementation invocation.
- Outer-loop worktree passes and review-fix passes.
- Deterministic shell tests using recording CLI stubs.

## Validation steps

1. Run `bash -n babysit-with-review.sh` and the CLI regression test.
2. Verify default execution selects Claude and retains current stage-specific model defaults.
3. Verify explicit Claude settings produce `claude -p ... --model MODEL --effort LEVEL` with the existing autonomous permission and final-result capture behavior.
4. Verify explicit Codex settings produce `codex exec ... --model MODEL -c model_reasoning_effort=\"LEVEL\"` with autonomous writable execution and final-message capture.
5. Verify invalid harnesses and missing switch values exit with status 2 before logs or lock files are created.

## Reviewer

Chris Robertson.

# Bounds

## Out of scope

- Separate implementer settings for the outer loop and review-fix passes.
- Implementers other than installed Claude and Codex CLIs.
- Pre-validating arbitrary model names or provider-specific effort values; the selected CLI remains authoritative.

## Assumptions-that-could-flip

- [ASSUMPTION] Review-fix passes use the selected implementer. Flips if: review remediation must use a dedicated third role.

# Signals

## Reviewer verification

The reviewer checks provider-specific argument construction, backward-compatible defaults, final-message/sentinel capture, and identical implementer selection across outer and review-fix passes.

## Regression test

Add `test-babysit-with-review-cli.sh` cases for implementer defaults, Claude forwarding, Codex forwarding, and parse-time failures.
