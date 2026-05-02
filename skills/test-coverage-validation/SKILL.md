---
name: test-coverage-validation
description: Assess whether a project has sufficient test coverage across unit, integration, contract, E2E, UX, performance, security, and accessibility testing, then prioritize gaps and optionally remediate them. Use for release readiness, audit prep, SRE/security review, onboarding a service, or requests like "audit our tests," "find test gaps," "is this well-tested," or "what coverage are we missing." Do not use for writing one already-scoped test; use normal coding assistance for that.
---

# Test Coverage Validation

## Purpose

Judge whether a project's tests are sufficient for its risk profile and
intended release, then prioritize gaps and (when appropriate) implement
remediation. Coverage is evaluated across eight levels: unit,
integration, contract, end-to-end, UX, performance, security, and
accessibility.

## Required workflow

Run these phases in order. Do not skip Phase 1.

1. **Establish scope and evidence.** Confirm what part of the project is being assessed and what evidence is available.
2. **Inspect artifacts.** Read configs, test directories, CI workflows, coverage reports, schemas. See `references/evidence-discovery.md`.
3. **Assess each applicable level.** Apply the rubric in `references/testing-level-rubric.md`. Mark levels as `not_applicable` with a reason when they don't apply (e.g., accessibility for a backend-only service).
4. **Derive overall verdict.** Use the rules in `references/verdict-logic.md`.
5. **Produce the assessment.** Use the template in `references/assessment-template.md`.
6. **Remediate only if requested and appropriate.** See `references/remediation-principles.md`.

## Required inputs

Before producing a verdict, you need at least one of:

- Read access to the codebase (preferred)
- Snippets covering test config, CI workflows, and a sample of the test suite
- A coverage report plus an architecture summary

If you have none of these, ask the user for evidence before assessing.
A verdict without evidence is worse than no verdict.

## Project-type calibration

Different project types have different release-critical levels. Identify
the project type before assessing, and weight findings accordingly.

| Project type | Release-critical levels | Often N/A |
|---|---|---|
| Backend service | unit, integration, contract, security, performance | accessibility, UX |
| Public API / SDK | unit, contract, security | UX, accessibility |
| Frontend web app | unit, integration, E2E, UX, accessibility, security | contract (consumer side only) |
| CLI / library | unit, integration | E2E, UX, accessibility, performance |
| Data pipeline | unit, integration, data-quality (under integration), performance | UX, accessibility |
| Infrastructure / IaC | integration, security | UX, accessibility, unit (often N/A) |
| Mobile app | unit, integration, E2E, UX, accessibility | contract (provider side) |

Use these as defaults; the user may override.

## Output discipline

The deliverable is a written assessment.

- **If the project files are accessible and writable:** create or update `TEST-COVERAGE-ASSESSMENT.md` in the project root. Reference it in chat; do not paste the full assessment back into chat.
- **If only snippets are available:** produce the assessment as an artifact or downloadable file. Mark source limitations explicitly in the document.
- **If no project evidence is available:** ask for it. Do not produce a speculative assessment.

The chat reply summarizes the verdict and points at the file.

## Remediation rules

Write tests only when **all** of the following hold:

- The codebase is available and editable
- The user has explicitly asked for implementation, not just assessment
- The gap is documented in the assessment file
- You can run the test or have the user run it before claiming success

When these conditions don't hold, produce **test specifications** —
detailed enough that an engineer could implement them — rather than
test code.

Always remediate at the level where the gap exists. A unit-level gap is
not fixed by adding an E2E test that happens to exercise the same code.

## When to stop

The skill is complete when:

- The assessment exists in the agreed location
- Each applicable level has a verdict (`sufficient`, `partial`, `inadequate`, `absent`, or `not_applicable` with a reason)
- An overall verdict is derived per `references/verdict-logic.md`
- A prioritized gap list exists with concrete, specific gap statements (see `references/assessment-template.md` for the standard for "specific")
- For Phase 2: P0 gaps are either remediated or have a remediation plan with owner and target date

## Things to avoid

- Listing absent tests without saying *which behavior* is untested
- Declaring a level "sufficient" because tests exist, without judging quality
- Adding new top-level levels beyond the eight; map novel concerns to the closest existing level (chaos → performance/integration; IaC validation → integration/security; migration tests → integration/E2E; observability tests → E2E/performance)
- Writing remediation tests for gaps that aren't documented in the assessment first
- Treating coverage percentage as a measure of sufficiency
