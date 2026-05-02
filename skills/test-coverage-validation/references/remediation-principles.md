# Remediation Principles

When moving from assessment to writing tests.

## Preconditions

Write actual test code only when **all** hold:

- Codebase is accessible and editable
- User explicitly asked for implementation, not only assessment
- The gap is documented in the assessment file
- You can run the test (or have the user run it) before claiming success

When any precondition is missing, produce **test specifications** —
detailed enough that an engineer could implement them — instead of
test code. A spec includes: file location, test name, setup, action,
assertions, teardown. It does not include framework-specific syntax
unless the user has confirmed the framework.

## Principles

### Fix at the level the gap exists

A unit-level gap is not fixed by adding an E2E test that happens to
exercise the same code. Adding higher-level tests to compensate for
missing lower-level tests is the inverted-pyramid pattern; it produces
slow, flaky suites that hide more than they reveal.

### Test behavior, not implementation

A test that breaks every refactor is testing the wrong thing. Tests
should describe the contract the code fulfills, not the steps it takes
to fulfill it.

### One bug, one test

Every production bug should ship with the test that would have caught
it. The test stays in the suite as a regression marker.

### Document the journey before automating it

For E2E and UX testing especially, write the journey in plain language
first. The test follows from the journey. Skipping the prose step
produces tests that pass without anyone knowing what they prove.

### Performance tests need targets

A load test without an explicit pass/fail criterion is a measurement,
not a test. Targets must be numeric and stated before the test is
written: "P95 latency under 800ms at 200 RPS sustained for 10 minutes."

### Security tests need a threat model

"Test for security" is not actionable. "Verify that user A cannot read
user B's records via API X" is. Every security test should reference
the specific threat it addresses.

### Accessibility needs real users (or close proxies)

Automated tests catch roughly 30% of real accessibility issues. For
release-critical accessibility coverage, manual screen-reader testing
is part of the testing plan, not an optional extra. The exception is
projects with no human-facing UI.

### Don't write tests to hit a coverage number

If a test's purpose is to raise the coverage percentage, it is not a
test, it is a comment. Coverage is a diagnostic of what's untested,
not a target.

## Anti-patterns to avoid during remediation

- **Backfilling tests for code that's about to be rewritten.** Wait, then test the new version.
- **Adding many small unit tests around one risky integration point.** The risk is at the integration boundary; add the integration test.
- **Writing tests in batches that all pass together.** Tests that have never been seen to fail are tests of nothing in particular. Each new test should be seen failing (against an intentionally broken or absent implementation) before being seen passing.
- **Adding tests as part of an unrelated change.** Test additions should land in their own commits or PRs so reviewers can evaluate them on their merits.

## Handoff to engineers

When producing test specifications instead of test code, format each
specification as:

```
### Test: <name describing the behavior verified>

**Level:** <unit / integration / contract / E2E / UX / performance / security / accessibility>
**File location:** <suggested path>
**Why this test exists:** <1-2 sentences linking to the gap or risk>

**Setup:**
- <preconditions>

**Action:**
- <what the test does>

**Assertions:**
- <what must be true after action>

**Teardown:**
- <cleanup, if any>

**Notes:**
- <framework hints, fixtures needed, dependencies>
```

A list of these specifications is a usable input to an engineer or
a coding agent. A list of vague gap statements is not.
