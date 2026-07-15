---
spec_type: task
id: ARLO-TASK-SELECTABLE-REVIEWER
status: draft
owners: [Chris Robertson]
depends_on: [ARLO-TASK-SELECTABLE-IMPLEMENTER]
parent_feature: ARLO-FEAT-REVIEW-CYCLE
fit_check: passed
complexity:
  total: 2
  band: trivial
  drivers: [surface_span]
  scored_on: 2026-07-15
---

# Frame

## TL;DR

Allow operators to select Claude or Codex as the independent review harness and independently choose its model and effort.

## Parent feature

ARLO-FEAT-REVIEW-CYCLE.

# Substance

## Repro or Given/When/Then

**Given** the current script, **when** a review pass runs, **then** Codex always performs the read-only review and its configured model and effort are implicit.

**Given** the updated script, **when** the operator passes `--reviewer claude|codex`, `--reviewer-model MODEL`, and/or `--reviewer-effort LEVEL`, **then** every review pass uses the selected harness, forwards non-empty model and effort selections through native arguments, and preserves the strict review-section output contract.

**Given** no reviewer switches, **when** a review cycle runs, **then** Codex remains the reviewer with its configured model and effort, preserving current behavior.

**Given** the same harness is selected for implementation and review, **when** the review cycle runs, **then** the roles still use separate invocations and the reviewer uses non-mutating controls.

## Affected surface

- Review preflight, provider invocation, output capture, retry/error classification, and log labels.
- CLI usage and startup configuration logging.
- Deterministic shell tests using Claude and Codex recording stubs.

## Implementation plan

1. Parse six role-specific switches: `--implementer`, `--implementer-model`, `--implementer-effort`, `--reviewer`, `--reviewer-model`, and `--reviewer-effort`; accept `--name=value` and `--name value` forms and preserve Claude/Codex defaults.
2. Introduce provider-neutral implementation and review dispatchers while retaining provider-specific command builders and output capture.
3. Map Claude effort to `--effort LEVEL`; map Codex effort to `-c model_reasoning_effort=\"LEVEL\"`; pass a role's model only when explicitly selected, except for the existing backward-compatible Claude implementation defaults.
4. Run implementers with autonomous writable permissions. Run Codex reviewers with `-s read-only`; run Claude reviewers in non-mutating plan permission mode and retain the prompt's explicit no-change rule.
5. Preserve strict review structural validation, Codex-specific MCP retry/outdated/credit detection when Codex is reviewer, and fail closed through the existing `review-incomplete` path for Claude review failures.
6. Keep review remediation assigned to the selected implementer, not the reviewer, and keep independent role invocations even when both roles use the same harness.
7. Update help, examples, version, comments, and startup logs to show resolved role policies.
8. Add a deterministic shell regression harness that sources an extracted test mode or runs parse-only/provider-dispatch paths with recording stubs, avoiding GitHub/network calls.

## Validation steps

1. Run `bash -n babysit-with-review.sh` and `test-babysit-with-review-cli.sh`.
2. Verify `--help` documents all six switches and both value syntaxes.
3. Verify a stubbed Claude reviewer receives its model, effort, and non-mutating permission mode and produces the strict review file.
4. Verify a stubbed Codex reviewer receives its model, reasoning effort, and read-only sandbox and produces the strict review file.
5. Verify default settings remain Claude implementer/Codex reviewer with no unintended model or effort override on Codex reviews.
6. Verify role settings never leak across commands and reviewer calls never receive implementation write permissions.
7. Verify invalid harness values and missing option values fail before runtime side effects.

## Reviewer

Chris Robertson.

# Bounds

## Out of scope

- Different reviewer settings by convergence cycle.
- Changing review prompt semantics, section parsing, merge policy, or the implementation/remediation sentinel protocol.
- Generalizing Codex-specific outage labels to failures that Claude does not emit.
- Direct API integrations or reviewer harnesses other than installed Claude and Codex CLIs.

## Assumptions-that-could-flip

- [ASSUMPTION] Claude plan permission mode is sufficiently non-mutating for repository review. Flips if: local policy requires OS-enforced read-only isolation, in which case Claude review must run in a read-only copy or external sandbox.
- [ASSUMPTION] One reviewer model and effort applies to every convergence cycle. Flips if: operators need cycle escalation, in which case role settings need per-cycle overrides.

# Signals

## Reviewer verification

The reviewer checks strict-output validation for both harnesses, role isolation, provider-specific failure behavior, backward-compatible defaults, and non-mutating review controls.

## Regression test

Extend `test-babysit-with-review-cli.sh` with reviewer defaults, Claude/Codex forwarding, strict-output validation, role isolation, and parse-time failures.
