# Assessment Template

Use this exact structure when producing `TEST-COVERAGE-ASSESSMENT.md`.
Fill every section. `not_applicable` is acceptable; "skipped" is not.

```markdown
# Test Coverage Assessment — <project name>

Assessor: <human or agent identifier>
Date: <YYYY-MM-DD>
Scope: <what was assessed: branches, services, packages>
Project type: <backend service / frontend app / CLI / library / data pipeline / IaC / mobile app / other>
Evidence access: <full repo / partial / snippets only / description only>
Confidence: <high / medium / low>

## Executive summary

Two paragraphs. The first says what's good. The second says what's
missing and what the highest-priority gaps are. A reader should be
able to make a release decision from these two paragraphs alone.

**Overall verdict:** <sufficient / partial / inadequate / absent>

**Release recommendation:** <ship / ship with documented risks / hold>

## Per-level findings

### Unit
- **What exists:** <concrete observations>
- **What is missing:** <specific behaviors not tested>
- **What is broken:** <tests that don't validate what they claim>
- **Verdict:** <sufficient / partial / inadequate / absent / not_applicable: reason>

### Integration
(same structure)

### Contract
(same structure)

### End-to-end (E2E)
(same structure)

### UX / user journey
(same structure)

### Performance
(same structure)

### Security
(same structure)

### Accessibility
(same structure)

## Anti-patterns observed

List of anti-patterns found in the suite, with file paths or test names
when possible. Empty list is acceptable if the suite is healthy.

## Prioritized gap list

| # | Gap statement | Level | Priority | Suggested approach |
|---|---|---|---|---|
| 1 | <strong gap statement per references/verdict-logic.md> | <level> | P0/P1/P2/P3 | <test sketch> |
| 2 | ... | ... | ... | ... |

Every row's gap statement must be **specific** per the rubric in
`references/verdict-logic.md`: what behavior, at which level, why it
matters, what the test would look like.

## Recommendations

Top 3–5 things to do, in order. Each one a concrete action with an
expected outcome. Example:

1. Add cross-tenant authorization tests covering all account-scoped endpoints (P0). Expected outcome: 403 or 404 returned for cross-tenant access; verified in CI.
2. Stand up a real-database integration suite for `OrderService` using Testcontainers (P1). Expected outcome: order lifecycle and failure-recovery paths verified against PostgreSQL.
3. ...

## Source limitations

State any limitations on the assessment:
- Files not accessed and why
- CI history not available
- Coverage reports stale or missing
- Areas of the system not inspected

If confidence is `low`, explicitly recommend raising confidence before
acting on the verdict.

## Out of scope

Note anything explicitly excluded from this assessment that a reader
might assume was included.
```

## Calibration check

Before finalizing the assessment, verify:

- A second engineer reading it could prioritize the same way.
- Each "missing" item is concrete enough that someone could write the test from the description.
- Each "broken" item identifies the specific test file and what it falsely claims to verify.
- The overall verdict matches the per-level evidence — if 5 of 8 levels are inadequate, the overall verdict cannot be `sufficient`.
- No recommendation requires inventing new infrastructure; if it does, that infrastructure is itself the first recommendation.
- Confidence level matches the evidence actually used.
