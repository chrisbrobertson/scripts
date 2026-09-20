---
spec_type: feature
id: BZR-FEAT-REVIEW-LIB
status: review
owners: [Chris Robertson]
depends_on: [BZR-SYS-BAZAAR]
parent_l1: BZR-PROD-BAZAAR-BUILDER
parent_l2: BZR-SYS-BAZAAR
fit_check: passed
complexity:
  total: 3
  band: moderate
  drivers: [surface_span, time_estimate]
  scored_on: 2026-09-19
---

# Frame

## TL;DR
`lib/bazaar-review.sh` is the convergent implementer/reviewer cycle extracted from `babysit-builder.sh` (control flow) and `babysit-work-prep.sh` (spec-mode prompts) into a sourced bash library with one entry point per concern. `babysit-with-review.sh` is not modified. Both Bazaar workers source the library; nothing else in the repo depends on it until the owner says so.

## Analog
Like pulling a copy-pasted retry-and-review routine out of three scripts into one shared module, keeping the behaviour byte-for-byte where the copies agree and picking the newest where they drifted.

## Reader & next action
Implementing agent: extract per the function map below, port the recording-stub harness first, and diff behaviour against the builder. Chris Robertson: confirm that the builder copy is the source of truth where copies differ.

## API surface fragment
*Implemented 2026-09-19 in `lib/bazaar-review.sh` v0.1.0 (1,188 lines); harness `test-bazaar-review-lib.sh`, 59 cases green.*
```bash
source "$SCRIPTS_DIR/lib/bazaar-review.sh"

# Implementer side (from babysit-builder.sh:650-716)
run_implementer  <prompt> <out_file> <run_dir> [stage_model]      # dispatches run_claude | run_codex_implementer
run_claude       <prompt> <out_file> <run_dir> [stage_model]      # honours IMPLEMENTER_MODEL / IMPLEMENTER_EFFORT
run_codex_implementer <prompt> <out_file> <run_dir>

# Reviewer side (from babysit-builder.sh:717-901)
review_with_retry <prompt>                                          # dispatches codex_review_with_retry | claude_review; rc 0-4 as ASF-FEAT-MCP-RESILIENCE
codex_review_with_retry <prompt>
claude_review     <prompt>
valid_review_structure <file>                                       # unchanged awk contract
count_blocking    <file>
reviewer_preflight                                                  # startup fatal on outdated/no-credits

# Cycle (from babysit-builder.sh:1093 run_build_cycle and babysit-work-prep.sh:1040 run_spec_review_cycle)
run_review_cycle --mode code|spec --pr <n> --worktree <dir> --branch <name> [--max-cycles N] [--validate-cmd CMD]
#                 [--spec-path P --spec-dir D --spec-guide G --ticket T --ticket-url U --ticket-title S --ticket-body B]
#   returns: 0 converged (BLOCKING=0)   10 cap hit   20 bail (reviewer rc 1 / implementer failed /
#            STUCK_REVIEW / no progress / validate-cmd failed / parse error)
#            2 transport outage   3 codex outdated   4 codex no credits
#   writes:  REVIEW_LAST_FILE  REVIEW_CYCLES_RUN  REVIEW_FAIL_REASON
#   side effects: reviewer output posted as PR comment each cycle; worktree pushed to origin/<branch>
#                 after each remediation and at the end; no labels, no draft toggle, no status post, no merge
post_codex_review_status <sha> <pr> [description]                   # caller decides when (build worker: finish only)

# Prompt registry (text moved verbatim from the source scripts, keyed by mode and cycle band)
review_prompt   <mode> <cycle>          # cycle 1, 2, 3-4 prescriptive, (code only) 5-6 adjudication; spec: 1, 2, 3+ prescriptive
review_prompt_name <mode> <cycle>
remediation_prompt <mode> <cycle>
remediation_model  <mode> <cycle>       # code: Sonnet 5 cycles 1-3, Opus 4-8 from 4; spec: Sonnet 5

# Test hook (from test-babysit-with-review-cli.sh pattern)
BABYSIT_TEST_MODE=1  → retry sleeps are skipped; the harness puts claude/codex/gh/sleep stubs on PATH
# Globals: LOG TMP_REVIEW TMP_CODEX_FULL TMP_REVIEW_RESULT REVIEW_WORKDIR REPO IMPLEMENTER REVIEWER (+ optional *_MODEL/*_EFFORT)
```

## Consumer
[BZR-FEAT-ISSUE-WORKER](L3-issue-worker.md) (`--mode spec`) and [BZR-FEAT-BUILD-WORKER](L3-build-worker.md) (`--mode code`).

# Substance

## What we know
- Owner decision 8 (2026-09-19): leave `babysit-with-review.sh` alone; extract the loop into a library for this tool.
- Function inventory in `babysit-builder.sh` (lines 644-1093): `slugify`, `run_claude`, `run_codex_implementer`, `run_implementer`, `count_blocking`, `valid_review_structure`, `codex_review_with_retry`, `claude_review`, `review_with_retry`, `reviewer_preflight`, `quarantine_pr`, `fail_build_cycle*`, `ensure_pr_marker`, `run_build_cycle`.
- Divergence measured 2026-09-19 (md5 of function bodies): `valid_review_structure` and `review_with_retry` identical in builder and work-prep; `run_claude` and `codex_review_with_retry` differ across all three scripts. `babysit-with-review.sh` additionally has adjudication mode (cycles 5-6) which work-prep deliberately omits for specs (babysit-specs README, 2026-09-10).
- The `ASF` corpus already specifies the reviewer contract (`ASF-FEAT-MCP-RESILIENCE`: return codes 0-4, telltales, `valid_review_structure`) and the cycle (`ASF-FEAT-REVIEW-CYCLE`: prescriptive from cycle 3, history from cycle 2). Those contracts are inherited, not redefined here.
- A recording-stub CLI harness exists for `babysit-with-review.sh` (`test-babysit-with-review-cli.sh`, `BABYSIT_TEST_MODE`); builder and work-prep have none.
- **Extraction outcome (2026-09-19):** `valid_review_structure` and `count_blocking` are md5-identical to the builder; all twelve prompt bodies are md5-identical to their sources; `codex_review_with_retry` and `claude_review` differ from the builder only by the `REVIEW_WORKDIR` rename, the `_bzr_sleep` shim, `${VAR:-}` guards for `set -u`, and the `_bzr_require` line. The builder's and work-prep's copies of `codex_review_with_retry` differed only in the worktree variable name, so no fix was lost.

## What we assume
- [ASSUMPTION] Where copies differ, the builder's version is the extraction source because it is the newest and already worktree-resident. Flips if: the diff shows a work-prep fix the builder lacks, in which case that fix is ported and logged. **Confirmed 2026-09-19:** the only difference was the worktree variable name.
- [ASSUMPTION] Labels and quarantine are the caller's job; the lib returns codes and posts review comments only. Flips if: duplication in the two workers becomes annoying, then a thin `quarantine_pr` helper moves into the lib.
- [ASSUMPTION] Adjudication mode (cycles 5-6) is available for `--mode code` and disabled for `--mode spec`, mirroring today's split. Flips if: the owner wants specs adjudicated too.
- [ASSUMPTION] The library is bash 3.2-compatible (macOS default) like its sources. Flips if: the sources already use bash 4 features, then the lib declares `#!/usr/bin/env bash` 4+. **Note 2026-09-19:** `_bzr_require` uses `${!name}` indirection, which is bash 2+; the harness ran under the `/usr/bin/env bash` on this Mac.

## Contract

### Request shape
See the surface fragment. All functions take explicit arguments plus the documented globals (`IMPLEMENTER`, `REVIEWER`, `*_MODEL`, `*_EFFORT`, `LOG`, `TMP_REVIEW`, `TMP_CODEX_FULL`).

### Response shape
Return codes as listed. `run_review_cycle` writes the final reviewer output path to `REVIEW_LAST_FILE` for the caller's summary comment.

### Invariants
1. Sourcing the lib has no side effects (no `set -e` changes, no traps, no temp files until a function is called).
2. `valid_review_structure` and the telltale regexes are byte-identical to `babysit-builder.sh` at extraction time; any later change is a logged spec amendment. **Amended 2026-09-20:** the spec-mode remediation prompt now permits edits to the corpus `index.md` and `log.md` and requires a log entry per cycle; the first pilot hit the cycle cap because the work-prep wording confined the implementer to one file while the reviewer (correctly, per spec-guide) blocked on a stale log.
3. The lib never adds or removes labels, never marks a PR draft/ready, never merges, never posts the commit status on its own.
4. `--mode spec` never enters adjudication.
5. Prompt text is stored once and referenced by key; no worker holds its own copy of a review prompt.
6. Every function is exercisable under `BABYSIT_TEST_MODE` with no network.

### Error model
Inherits `ASF-FEAT-MCP-RESILIENCE` (0-4) for reviewer calls. `run_review_cycle` maps: reviewer 2/3/4 → same code; reviewer 1, implementer non-zero, `STUCK_REVIEW`, no new commit, `--validate-cmd` failure, or a `count_blocking` parse error → 20 with `REVIEW_FAIL_REASON` set; cap → 10.

### Idempotency
A cycle is idempotent per (PR head SHA, cycle number); history file makes re-runs append rather than restart.

### Versioning policy
`BZR_REVIEW_LIB_VERSION` string; workers assert a minimum at source time.

## Performance budget
Unchanged from the sources: reviewer 1-7 min per call, implementer 5-30 min per remediation.

## Security model
Inherits. Telltale regexes are fixed strings (see `SECURITY-REVIEW-PLAN.md` in `babysit-specs/` §4).

## Telemetry contract
Same `[codex]` / `[review]` log lines as the sources, prefixed by the caller's tag. `run_review_cycle` additionally logs `cycle=<k> blocking=<b> new=<n> recurrence=<r>`.

## Verifiers
- Tech lead: Chris Robertson
- QA: ported recording-stub harness (`test-bazaar-review-lib.sh`), green before either worker lands.

## Failure modes & blast radius
- **Behaviour drift during extraction:** every Bazaar review changes. Mitigation: harness replays the QA-TEST-PLAN TC-3.x cases against the lib; diff of function bodies committed in the extraction PR.
- **Global-variable coupling:** a worker forgets to set `LOG`. Mitigation: each entry point asserts its required globals and exits 2 with the missing name.
- **Prompt registry key typo:** wrong prompt for a cycle. Mitigation: `review_prompt` fails loudly on unknown keys.

# Bounds

## Out of scope
Changing review semantics, touching `babysit-with-review.sh`.

## Assumptions-that-could-flip
- **Bash library.** Flipping to Python would let the workers share JSON state cleanly but breaks the SSH-stdin and single-file conventions of this repo.

## Composes with / replaces
Composes with `ASF-FEAT-REVIEW-CYCLE` and `ASF-FEAT-MCP-RESILIENCE` (their contracts, reused). Replaces the review-cycle code in `babysit-builder.sh` and `babysit-work-prep.sh`, which are deleted in plan phase 5 (owner, 2026-09-19); `babysit-with-review.sh` keeps its own copy by decision 8.

# Signals

## Acceptance tests
1. **Given** the lib is sourced in a fresh shell, **when** `set -u` is on, **then** no error and no files created.
2. **Given** stubbed Codex output with `Transport send error:` three times, **when** `review_with_retry` runs, **then** rc 2 and the log shows the 60s/300s waits (sleep stubbed).
3. **Given** a stubbed review with BLOCKING 1 then 0, **when** `run_review_cycle --mode code` runs, **then** rc 0 after two cycles and two PR comments recorded by the `gh` stub.
4. **Given** `--mode spec` and cycle 5, **when** the prompt is selected, **then** it is the prescriptive spec prompt, not adjudication.
5. **Given** cap 2 and BLOCKING never reaching 0, **when** the cycle runs, **then** rc 10.
6. **Given** the extraction PR, **when** `awk` extracts `valid_review_structure` from lib and builder, **then** md5 matches.
7. **Given** a caller with `LOG` unset, **when** any entry point is called, **then** exit 2 naming `LOG`.
8. **Given** the QA-TEST-PLAN TC-3.1 to TC-3.8 cases, **when** replayed against the lib, **then** all pass.

## Telemetry events tied to L1 KPIs
Cycle counts and reviewer rc distribution, as in ASF.

## AEAB cases
N/A.

## Kill criteria
If maintaining two copies (lib and `babysit-with-review.sh`) causes a fix to be missed in one for a second time, revisit decision 8 with the owner.
