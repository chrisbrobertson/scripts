# Testing Level Rubric

For each applicable level, evaluate four questions:

1. **What exists?** What tests are present at this level today?
2. **What is missing?** What categories of test that should exist are absent?
3. **What is broken?** What tests exist but don't actually validate what they claim to?
4. **Verdict.** `sufficient` / `partial` / `inadequate` / `absent` / `not_applicable` (with reason).

The rubrics below are guidelines, not absolutes. A small CLI library may
legitimately have no unit tests for setters; a thin proxy service may
have minimal unit logic worth testing. Use judgment, and document the
reasoning when deviating from defaults.

---

## Level 1 — Unit tests

**Purpose.** Verify individual functions, classes, or modules behave
correctly in isolation. Fast, deterministic, no external I/O.

**Look for:**

- Public surfaces have behavioral coverage (not necessarily one-test-per-function)
- Edge cases tested explicitly: empty inputs, null/undefined, boundary values, malformed input, unicode, very long inputs
- Error paths are tested, not just happy paths
- I/O is mocked, stubbed, or replaced with in-memory equivalents
- Tests run in milliseconds; the full unit suite finishes in seconds-to-low-minutes

**Red flags:**

- Assertion-free or weak assertions (`expect(x).toBeTruthy()` on objects)
- Tests that import the entire application to test one function
- Tests that pass when the function under test is replaced with a stub
- Heavy mock setup, suggesting the unit is doing too much
- Coverage theater — high line coverage with assertions that don't verify behavior

**Sufficiency rubric:**

- `sufficient` — Public surfaces have behavioral coverage; edge cases explicit; error paths covered; tests fast and deterministic.
- `partial` — Happy paths covered; edge cases sparse; some error paths untested.
- `inadequate` — Tests exist but assertions are weak or coverage focuses on trivial accessors.
- `absent` — No unit tests, or "unit tests" are integration tests in disguise.

---

## Level 2 — Integration tests

**Purpose.** Verify two or more components work together correctly
within the same process. Tests real component wiring and internal
contracts.

**Look for:**

- Significant module-to-module boundaries are tested
- Persistence is verified against a real test database or representative test container; mocks here often defeat the purpose
- Both successful and failed interactions covered: timeouts, partial failures, retry behavior
- Transaction boundaries — does a partial failure leave consistent state?
- Tests are isolated from each other; one test's data doesn't leak

**Red flags:**

- Integration tests that mock the very things they should integrate
- Hand-managed setup/teardown that drifts out of sync with schema changes
- Order-dependent tests (passes locally, fails in CI under different ordering)
- "Integration tests" that don't actually integrate — unit tests with longer setup

**Sufficiency rubric:**

- `sufficient` — Major component pairs tested; failure modes covered; isolation verified; persistence tested against real backing services.
- `partial` — Happy-path integration covered; failure modes thin; persistence partly mocked.
- `inadequate` — Integration tests exist but overuse mocks for the integration boundary itself.
- `absent` — Component interaction is verified only via E2E or not at all.

---

## Level 3 — Contract tests

**Purpose.** Verify that the agreement between two services (or between
a service and its consumers) holds. Catches breaking changes before
production. Critical for any system with more than one deployable unit.

**Look for:**

- Producer-side: every public API has a contract describing requests, responses, errors, and breaking-change rules
- Consumer-side: every external dependency has a test verifying the consumer handles real provider responses
- Tests run on every CI build, not only at release
- Schema changes that break contracts fail CI immediately
- Backward-compatibility windows are explicit when needed

**Red flags:**

- A shared OpenAPI doc with no test that verifies producer matches it
- Consumer-driven contracts that don't run against the provider
- Schemas in code and docs that drift apart
- Breaking changes shipped without deprecation cycles

**Sufficiency rubric:**

- `sufficient` — All public APIs have contracts; consumer and producer both verify; breaking changes caught in CI.
- `partial` — Contracts exist for some APIs; verification incomplete.
- `inadequate` — Schemas documented but not tested.
- `absent` — Service depends on undocumented assumptions about other services.

---

## Level 4 — End-to-end (E2E) tests

**Purpose.** Verify the whole system behaves correctly with all
components running. Catches issues no lower level can — config drift,
deployment errors, real-world dependency interactions.

**Look for:**

- Small set of E2E tests covering the most critical paths (sign-in, primary user action, primary admin action, billing, etc.)
- Tests run against a deployed environment that mirrors production reasonably
- Tests are idempotent — they clean up or run in disposable environments
- Failures provide enough information to diagnose without re-running
- The suite is bounded; E2E should be a small fraction of total test count

**Red flags:**

- Suites that take hours and get routinely skipped
- Tests depending on specific data already in the test environment
- Tests that mock significant parts of the system (defeats the purpose)
- Inverted pyramid — far more E2E than unit tests
- Flaky tests retried until they pass; each retry hides a real signal

**Sufficiency rubric:**

- `sufficient` — Critical journeys covered; tests stable and fast enough to gate releases.
- `partial` — Some critical paths covered; flakiness tolerated.
- `inadequate` — E2E tests exist but rarely pass on first run.
- `absent` — No E2E coverage; releases rely on manual smoke testing.

---

## Level 5 — UX / user journey tests

**Purpose.** Verify the system serves real users completing real tasks.
Distinct posture from E2E: E2E asks "does the system work end to end?"
UX testing asks "can a user actually accomplish what they came here to
do?"

**Look for:**

- Documented user journeys: who the user is, what they want, what success looks like
- Tests that follow these journeys (typically browser- or app-driven)
- Verification of UX qualities: responsiveness, sensible error messages, recovery paths
- Coverage of unhappy paths users encounter: bad input, network interruption, session expiry, permission denied
- Where applicable: visual regression on critical screens

**Red flags:**

- "UX is covered by E2E tests" — usually means UX qualities aren't really tested
- Tests that bypass the actual UI to test API calls (useful but not UX testing)
- No journey documentation; tests written from a developer's perspective
- Visual regression that's been noisy so long it's been disabled

**Sufficiency rubric:**

- `sufficient` — Documented journeys with UX-focused tests; unhappy paths included.
- `partial` — Some journeys tested; UX-specific assertion quality uneven.
- `inadequate` — Journey concept exists but tests are functional only.
- `absent` — No journey-aware testing; UX issues caught by users in production.

---

## Level 6 — Performance tests

**Purpose.** Verify the system meets latency, throughput, and resource
targets under expected and stress loads.

**Look for:**

- Documented performance targets: P50/P95/P99 latencies, throughput, error rate under load, recovery time after spikes
- Load tests that exercise realistic traffic patterns, not only synthetic peak
- Stress tests that find the breaking point and verify graceful degradation
- Soak tests for memory leaks and slow degradation
- Performance baselines tracked over time so regressions are visible
- Tests run on infrastructure resembling production

**Red flags:**

- Performance targets that are aspirational and untested
- Load tests that ramp to a fixed load and stop, with no breaking point identified
- Performance regressions detected only via user complaints
- "We use a CDN" cited as performance testing
- Production observability cited as performance *testing* (it's monitoring; different)

**Sufficiency rubric:**

- `sufficient` — Targets documented, load and stress tested, baselines tracked.
- `partial` — Some performance testing exists; targets vague.
- `inadequate` — Ad-hoc performance testing only.
- `absent` — No performance testing; production is the load test.

---

## Level 7 — Security tests

**Purpose.** Verify the system handles authentication, authorization,
untrusted input, secrets, and known vulnerability classes correctly.
Layered; multiple kinds of testing fall under this.

**Look for:**

- **AuthN tests:** valid creds succeed, invalid creds fail, brute-force protection, MFA paths, session expiry
- **AuthZ tests:** users cannot access other users' data; role boundaries enforced; horizontal and vertical privilege escalation blocked
- **Input handling:** the attack classes relevant to the stack (injection, XSS, deserialization, path traversal, XXE, etc.)
- **Secret handling:** secrets not in logs/errors/version control; rotation works; revoked tokens rejected
- **Dependency scanning:** known-CVE scanning in CI; updates tracked
- **SAST and DAST:** static and dynamic security testing with triaged results
- **Penetration testing:** for higher-stakes systems, regular external pen-tests with documented remediation

**Red flags:**

- "We use HTTPS" cited as security testing
- AuthN tests exist but AuthZ tests are absent (extremely common)
- Secrets in source control, even "test" secrets that work against real environments
- Vulnerability scan output that no one reads
- Security review performed entirely by the team that wrote the code

**Sufficiency rubric:**

- `sufficient` — AuthN and AuthZ tested deeply; input handling tested for relevant attack classes; secret handling verified; dependencies scanned; SAST/DAST in CI.
- `partial` — Some security testing exists; coverage uneven (often AuthN-only).
- `inadequate` — Security depends on framework defaults with no verification.
- `absent` — No deliberate security testing.

---

## Level 8 — Accessibility tests

**Purpose.** Verify the system is usable by users with disabilities.
A moral baseline and, in many jurisdictions, a legal requirement.

**Look for:**

- Automated a11y scans (axe, pa11y, Lighthouse a11y) on critical pages in CI
- WCAG conformance level documented (A, AA, AAA) and tested against
- Screen reader testing — actual usage with NVDA, JAWS, or VoiceOver, not only automated checks
- Keyboard-only testing — every interaction reachable without a pointer
- Color contrast tested on rendered pages, not only design tokens
- Form errors announced to assistive tech, not only visually highlighted
- Focus management tested — focus traps, focus restoration after modals close

**Red flags:**

- "We ran Lighthouse once" cited as accessibility testing
- Automated scans pass but no human has used the product with a screen reader (automated tools catch ~30% of real issues)
- Color contrast measured on mockups but never on rendered pages
- Accessibility considered at design time but not tested as it ships
- Custom UI components without ARIA attributes

**Sufficiency rubric:**

- `sufficient` — Automated and manual a11y testing; WCAG conformance verified; assistive tech tested.
- `partial` — Automated checks in CI; manual testing inconsistent.
- `inadequate` — One-time accessibility check at launch.
- `absent` — No accessibility testing.

---

## Cross-cutting concerns

Map these into the closest existing level rather than creating new
top-level categories:

| Concern | Maps to |
|---|---|
| Chaos testing (controlled failure injection) | Performance or Integration, depending on focus |
| Disaster recovery / backup restore | Integration or E2E |
| Migration testing (schema, data) | Integration or E2E |
| Data quality testing (pipelines) | Integration |
| Observability / alert testing | E2E or Performance |
| IaC validation (Terraform, K8s manifests) | Integration and/or Security |
| Property-based / fuzz testing | Unit (typically) |
| Mutation testing | Quality of unit tests, not a separate level |

For genuinely novel concerns, document under the closest level and note
the deviation in the assessment.

---

## The pyramid

Healthy default shape:

```
              /\
             /UX\
            /----\
           / E2E  \
          /--------\
         /Integration\
        /------------\
       /     Unit     \
      /----------------\
```

Performance, security, and accessibility cut across the pyramid at the
level where they make sense.

**When to deliberately invert.** Some systems (very thin services, glue
code, declarative infrastructure) genuinely have little to unit test. In
those, more weight at integration or E2E is correct. The test of whether
the inversion is healthy: is the suite fast and stable? If slow and
flaky, the inversion is masking a problem.

---

## Suite-level anti-patterns

These appear regardless of level:

- **Assertion-free tests** that exercise code without asserting anything specific
- **Single-assertion-per-test obsession** that produces noise instead of clarity
- **Fixture sprawl** with no organizing principle, suggesting no canonical sample states
- **The slow file** that takes 90% of the runtime and gets skipped under pressure
- **The skip graveyard** — tests marked `skip` or `xfail` with no expiry
- **Mocking the system under test** until tests verify the mocks rather than the code
- **Tests that pass after deleting the implementation** (run periodically as a check)
- **Coverage as a goal** — 80% line coverage tells you nothing about whether the right things are tested
- **No test plan for new features** — code lands without anyone deciding what level(s) to test at
- **Tests as accidental documentation** with names like `test_thing_works` and no comments
