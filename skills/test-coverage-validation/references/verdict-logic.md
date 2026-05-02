# Verdict Logic

How to derive the overall verdict from per-level findings, and how to
classify gap priority.

## Per-level verdict values

Each applicable level gets one of:

- `sufficient` — meets the rubric without significant exceptions
- `partial` — meets some criteria, has notable gaps
- `inadequate` — tests exist but don't actually validate what they claim, or coverage is so thin it doesn't materially reduce risk
- `absent` — no meaningful testing at this level
- `not_applicable` — with a stated reason (e.g., "backend service, no UI")

Marking a level `not_applicable` requires a reason. "Doesn't apply" is
not a reason. "Backend service with no user-facing surface" is.

## Release-critical levels

Release-criticality depends on project type. See the calibration table
in SKILL.md. As a guideline:

- A level is **release-critical** when a serious gap at that level can
  cause user-visible production issues that the team would normally
  consider blocking
- A level is **important but not release-critical** when gaps degrade
  quality but don't directly block release
- A level is **non-applicable** when it doesn't fit the project type at
  all

## Overall verdict rules

Apply in order. The first matching rule wins.

1. **`absent`** — if testing evidence is missing for most applicable levels, OR if no test suite runs in CI at all.
2. **`inadequate`** — if any release-critical level is `inadequate` or `absent`, OR if any P0 gap exists, OR if the test suite is so flaky it can't gate releases.
3. **`partial`** — if at least one important level is `partial`, but no P0 gaps, and release-critical levels are at least `partial`.
4. **`sufficient`** — all release-critical levels are `sufficient`; no P0 gaps; suite is stable and runs in CI.

A `sufficient` verdict does not mean "no gaps." It means "no gaps that
would block a release for a reasonable team."

## Gap priority

Each gap is tagged:

- **P0** — Block release. The gap represents a real risk of user harm,
  data loss, security breach, compliance violation, or service outage
  that's reasonably likely to manifest.
- **P1** — Fix this sprint. The gap reduces confidence enough that
  ongoing development is risky; not a blocker today but blocking soon.
- **P2** — Backlog. Real gap, not urgent. Track and address as
  schedule allows.
- **P3** — Acceptable risk. Gap exists, has been weighed, and the team
  accepts it (with explicit owner). Document the rationale.

## Gap statement quality

A gap statement is **specific** if it answers all four:

1. **What behavior** is untested?
2. **At which level** should the test exist?
3. **Why does this matter** — what user-visible or operational risk?
4. **What would the test look like** — sketch, not implementation?

### Weak vs strong gap statements

**Weak (do not produce these):**

- "Security tests are missing."
- "Need more integration tests."
- "Coverage is too low."
- "Performance is untested."

**Strong:**

- "No authorization tests cover cross-tenant access on `GET /accounts/:id`. P0 release blocker — user A may retrieve user B's account data. Add API-level tests asserting user A receives 403 (or 404) for account IDs owned by user B."
- "No integration tests cover the partial-write recovery path in `OrderService.placeOrder`. P1 — a network failure between order persist and inventory decrement leaves orders in `pending_inventory` state with no recovery. Add an integration test simulating inventory-service failure mid-call and asserting the order is either rolled back or marked for reconciliation."
- "No load test exercises the `/search` endpoint above 50 RPS. P1 — production sees ~200 RPS at peak; latency behavior above 50 RPS is unknown. Add a k6 ramp-up test from 50 to 250 RPS asserting P95 < 800ms."

The strong examples are usable as input to a remediation task. The
weak ones are not.

## Confidence

Every assessment includes a confidence level reflecting evidence
quality:

- **High** — Direct codebase access, recent CI runs, coverage reports, sample of test files inspected.
- **Medium** — Partial evidence (configs and snippets, or recent reports without code access).
- **Low** — Description-only or stale evidence (old reports, second-hand summary).

Decisions made from a low-confidence assessment should not block
releases without first raising confidence.

## When the verdict and the team disagree

If the team believes coverage is sufficient but the assessment says
otherwise, the disagreement itself is information. Surface it
explicitly:

- What evidence the assessment used
- What evidence the team is using
- Where the gap in shared evidence lives

Resolve by raising shared evidence (running coverage, inspecting
specific tests together) rather than by negotiating the verdict.
