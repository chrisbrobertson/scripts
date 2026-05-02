# Evidence Discovery

Concrete inspection procedure for gathering evidence before assessing
test coverage. Apply each section as relevant to the project type.

## Universal first pass

Look for these regardless of stack:

- `README.md` and any `CONTRIBUTING.md` — often state testing expectations
- Top-level test directories: `test/`, `tests/`, `spec/`, `__tests__/`, `e2e/`, `integration/`
- CI configuration: `.github/workflows/`, `.gitlab-ci.yml`, `.circleci/`, `Jenkinsfile`, `azure-pipelines.yml`, `.buildkite/`
- Coverage configuration: `codecov.yml`, `.coveragerc`, `sonar-project.properties`, `coverage.json`
- Documentation about testing: `docs/testing.md`, `TESTING.md`, ADRs mentioning tests

## Stack-specific inspection

### JavaScript / TypeScript

Files to read:
- `package.json` — `scripts.test`, `scripts.test:*`, `devDependencies`
- `jest.config.*`, `vitest.config.*`, `mocha.config.*`, `karma.conf.*`
- `playwright.config.*`, `cypress.config.*`, `webdriverio.conf.*`
- `tsconfig.test.json` if present

Signals:
- Multiple test scripts (`test`, `test:integration`, `test:e2e`) suggests pyramid awareness
- Single `test` script that runs everything suggests no pyramid separation
- Presence of `msw`, `nock`, `wiremock` — mock-heavy integration approach
- Presence of `testcontainers` — real-database integration approach

### Python

Files to read:
- `pyproject.toml` (sections `[tool.pytest]`, `[tool.coverage]`, `[project.optional-dependencies]`)
- `pytest.ini`, `setup.cfg`, `tox.ini`
- `conftest.py` files at every level
- `requirements*.txt` for test-specific files

Signals:
- `tox.ini` with multiple environments suggests matrix testing
- `conftest.py` with shared fixtures — assess fixture quality
- Presence of `hypothesis` — property-based testing in use
- Presence of `pytest-django`, `pytest-flask`, `pytest-asyncio` — integration testing scaffolded

### Go

Files to read:
- `go.mod` — testing dependencies
- `*_test.go` files alongside source
- Build tags in test files (`//go:build integration`)

Signals:
- Build tags separating unit from integration tests is healthy
- Heavy use of `gomock` — verify mocks aren't masking real behavior
- Presence of `testcontainers-go` — real integration testing
- `BenchmarkXxx` functions — performance testing in code

### Java / Kotlin

Files to read:
- `pom.xml` or `build.gradle(.kts)` — test dependencies, surefire/failsafe config
- `src/test/`, `src/integrationTest/`, `src/e2eTest/`
- `application-test.yml` and Spring test profiles

Signals:
- Separate source sets for unit vs integration is healthy
- Presence of Testcontainers or Wiremock — integration approach
- JUnit 5 vs JUnit 4 — older suites often have legacy patterns
- Pact or Spring Cloud Contract — contract testing in place

### Rust

Files to read:
- `Cargo.toml` — `[dev-dependencies]`, `[[test]]` sections
- `tests/` directory at crate root (integration tests)
- `#[cfg(test)]` modules inline (unit tests)
- `benches/` directory (performance)

Signals:
- Separation between inline `#[cfg(test)]` and `tests/` directory is the language convention
- Presence of `proptest` or `quickcheck` — property-based testing
- `criterion` in dev-deps — performance benchmarking

### Ruby

Files to read:
- `Gemfile` — `:test` and `:development` groups
- `spec/`, `test/`, `features/`
- `.rspec`, `spec_helper.rb`, `rails_helper.rb`

Signals:
- RSpec vs Minitest — both fine; quality depends on how they're used
- Presence of `vcr` or `webmock` — external HTTP testing approach
- Capybara + Selenium/Cypress — browser/E2E testing
- `factory_bot` setup — fixture quality indicator

### Infrastructure-as-Code

Files to read:
- Terraform: `*.tf`, `terratest/`, `terraform validate` and `terraform plan` in CI
- CloudFormation: `cfn-lint` config, `taskcat.yml`
- Kubernetes: `kustomize` overlays, `helm test/` charts, policy tests (OPA, Kyverno)
- Pulumi: language-native test files

Signals:
- `terratest` or equivalent — actual integration testing of infra
- Policy-as-code (OPA, Sentinel, Kyverno) — security/compliance testing
- `terraform plan` in CI without `apply` is *not* testing — it's linting

## Cross-cutting evidence

### Contract testing
- Pact files: `pacts/`, `pact_helper.*`, broker URLs
- OpenAPI/Swagger: `openapi.yaml`, `swagger.json` — and whether tests reference them
- GraphQL: schema files, schema-validation tests
- Protobuf/gRPC: `.proto` files, generated stub tests

### Performance testing
- `k6/`, `gatling/`, `jmeter/`, `locust/` directories
- Load test results stored in repo or referenced from external system
- SLO/SLI documentation
- APM integration (Datadog, New Relic, Honeycomb) — observability for production performance, not the same as performance testing

### Security testing
- SAST config: `.semgrep.yml`, `.sonarcloud.properties`, CodeQL workflows, Snyk config
- Dependency scanning: Dependabot, Renovate, `npm audit` in CI
- Secret scanning: `gitleaks.toml`, GitHub secret scanning, `trufflehog` in CI
- DAST: ZAP baseline scans, Burp Suite reports
- Pen test reports (often outside the repo; ask)

### Accessibility testing
- `axe-core` or `pa11y` in dev-deps and in CI
- Lighthouse CI config
- Visual regression: Percy, Chromatic, Applitools
- Manual a11y test plans (often in docs, not code)

## What to ask the user when evidence is thin

If you can't find clear evidence:

- "Where do the integration tests live? I see unit tests in X but nothing larger."
- "Is there a CI workflow that runs the full suite? I only see the build step."
- "Do you have a coverage report from the most recent CI run?"
- "Is there an external system (Pact broker, k6 cloud, BrowserStack) where some tests run?"
- "What's the deployment unit — service, monorepo, single binary? It changes which levels apply."

Ask these *before* producing an assessment, not after.

## Sample commands by ecosystem

When you have shell access in the project:

```bash
# Universal
find . -type d \( -name "test*" -o -name "spec*" -o -name "__tests__" \) | head -20
find . -name "*.test.*" -o -name "*_test.*" -o -name "*.spec.*" | head -20

# Coverage report inspection
find . -name "coverage*" -type d
find . -name "*.lcov" -o -name "coverage.xml" -o -name "coverage.json"

# CI workflow inspection
ls -la .github/workflows/ 2>/dev/null
cat .github/workflows/*.yml 2>/dev/null | grep -E "(test|coverage|e2e|integration|security)"

# JS/TS
cat package.json | jq '.scripts | to_entries | map(select(.key | startswith("test")))'

# Python
grep -E "^\[tool\.(pytest|coverage)" pyproject.toml 2>/dev/null
ls conftest.py **/conftest.py 2>/dev/null

# Go
grep -r "//go:build" --include="*.go" | head
go test -list '.*' ./... 2>/dev/null | head -20
```

These are illustrative; adapt to the actual environment.
