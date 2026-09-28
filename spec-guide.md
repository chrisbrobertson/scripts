# Spec Guide — schema for TIF L1–L4 spec corpora

This file is the **schema document** (in the [LLM Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) sense) for spec-driven development in this repo: it defines how a `<project>-specs/` directory is structured, what conventions its pages follow, and what workflows an LLM agent runs when creating, querying, or maintaining specs. An agent working on any spec corpus in this repo reads this file first.

The format was reverse-engineered from `babysit-specs/` (the only worked example as of 2026-09-09). For a concrete style reference at each layer: `babysit-specs/L3-mcp-resilience.md` is the cleanest small example, `babysit-specs/L1-babysit-with-review.md` and `L2-autonomous-dev-system.md` for those layers, `L4-selectable-implementer.md` for a task.

"TIF" = **T**rustable, **I**ntuitive, **F**lexible — the three qualities each spec is meant to demonstrate: trustable (grounded in evidence, assumptions flagged), intuitive (a named reader knows what to do with it), flexible (bounds and flip-conditions are explicit so scope changes don't require a rewrite).

## Architecture

A spec corpus has three layers:

**Raw sources** — the implementation itself (scripts, code, `--help` output), tickets and issues, PRs and review outputs, and decisions the owner makes in conversation. These are the source of truth. The spec agent reads them but never treats a spec as overriding them — specs *cite* them as evidence in "What we know", and when spec and implementation disagree, that's a lint finding, not a license to edit the code to match the spec.

**The wiki** — the `<project>-specs/` directory: L1–L4 spec pages, supporting non-spec pages (QA plans, security review plans, filed-back analyses), `index.md`, and `log.md`. The LLM drafts and maintains this layer — pages, cross-references, index, and log all stay consistent because the agent updates them together.

**The schema** — this file. It's co-evolved by the owner and the LLM: when a convention changes or a new page type is needed, the change lands here first, then propagates to corpora as they're touched.

**Division of labor.** The human curates sources, makes design decisions, and signs off — every `Approvers`/`Verifiers`/`Reviewer` entry is a real name, and only the owner moves a spec to `status: ready`. The LLM does everything else: drafting, sorting known-vs-assumed, cross-referencing, index and log upkeep, consistency checks. Standing rule: the agent never infers or assumes a design decision and writes it into a spec — it surfaces the decision and gets an explicit answer first.

## The four layers

| Layer | `spec_type` | What it captures | One per... |
|---|---|---|---|
| **L1** | `product` | Why this exists, for whom, at what scale, what it costs, when to kill it | product/initiative |
| **L2** | `system` | How components fit together, their contracts, SLOs, failure domains | system/architecture |
| **L3** | `feature` | One feature's/function's contract: request/response shape, invariants, error model | feature or internal function |
| **L4** | `task` | One bounded unit of implementation work, Given/When/Then, validation steps | task/PR-sized change |

A spec can be layered without every level existing yet — e.g. an L4 task can ship before its parent L3 is marked `ready`, as long as `parent_feature` points at it. Not every change needs all four layers: a small fix to existing behavior may only need an L4, or may be folded into an existing L1/L2's prose as an amendment (see "Amending vs. new spec" below) rather than spawning a new file.

## Required frontmatter by layer

All layers share these keys:

```yaml
spec_type: product | system | feature | task
id: <PREFIX>-<LAYER-TAG>-<SLUG>       # see ID scheme below
status: review | ready                # observed values; draft/deprecated presumably valid too
owners: [Full Name]
depends_on: [<ID>, ...]               # other spec IDs this one needs; [] if none
fit_check: passed                     # see "Fit check" below
complexity:
  total: <number>
  band: trivial | moderate | ...      # see "Complexity scoring" below — thresholds not formally pinned down in this repo
  drivers: [driver_name, ...]
  scored_on: YYYY-MM-DD
```

Layer-specific additions:

- **L1** adds `experience_authority: none|<role>` (who owns the UX/experience call — `none` if not applicable).
- **L2** adds `serves_l1: [<L1 ID>, ...]` — which product spec(s) this system serves.
- **L3** adds `parent_l1: <L1 ID>` and `parent_l2: <L2 ID>` — both, even though `depends_on` already lists the L2.
- **L4** adds `parent_feature: <L3 ID>` — the one feature this task implements against.

### ID scheme

`<PREFIX>-<TAG>-<SLUG>`, all caps, hyphenated:
- `PREFIX` — a short project codename (this repo currently uses `ASF`; pick one per project and keep it stable — see "Picking a prefix" below).
- `TAG` — `PROD` (L1), `SYS` (L2), `FEAT` (L3), `TASK` (L4).
- `SLUG` — descriptive, matches the file's slug, e.g. `BABYSIT-WITH-REVIEW`, `AUTONOMOUS-DEV`, `BUILDER`, `SELECTABLE-IMPLEMENTER`.

File naming mirrors this: `L<n>-<lowercase-slug>.md` in a `<project>-specs/` directory (e.g. `babysit-specs/L3-builder.md`), with `index.md` and `log.md` alongside (see "Index and log" below).

## Section layout by layer

Every layer uses the same four top-level parts — `# Frame`, `# Substance`, `# Bounds`, `# Signals` — but which subsections appear under each differs by layer.

### L1 (product)

```
# Frame
## TL;DR                        — 2-4 sentences, what it is and for whom
## Analog                       — "like X, but Y" comparison to something familiar

# Substance
## What we know                 — grounded facts, cite evidence/source
## What we assume               — [ASSUMPTION] bullets, each with "Flips if: ..."
## Scale envelope                — users at launch/6mo/18mo, volume, growth curve
## Business case                 — revenue model, value prop, cost model, unit economics, success metric
## Approvers                     — Product / Engineering / Finance-GTM / Compliance sign-off owners
## Failure modes & blast radius  — what happens if X fails, how bad, and the mitigation

# Bounds
## Out of scope
## Assumptions-that-could-flip   — architecture-level bets and what flipping them would require
## Composes with / replaces

# Signals
## Leading indicators (first 30-90 days)
## Lagging indicators (90+ days)
## Kill criteria                 — numeric thresholds that trigger kill/pivot
```

### L2 (system)

```
# Frame
## TL;DR
## Analog
## Reader & next action          — who reads this and what they do next
## Component diagram             — ASCII box diagram + prose "Authoritative surface" note

# Substance
## What we know
## What we assume
## Cross-component contracts     — one ### subsection per integration point:
                                    Protocol, Request shape, Response shape, Retry policy,
                                    Idempotency (pick the fields that apply)
## SLOs and latency budgets      — p50/p95/p99 per operation, or "deferred" + observed numbers
## Failure-domain map            — cell scope, blast radius per failure class, degraded modes
## <project>-infra.yaml dependencies   — or "N/A" + external dependency list
## Compliance posture            — data residency, SOC2 impact, retention, PII, cross-region
## Verifiers                     — Architecture / SRE / Security / Compliance sign-off owners
## Failure modes & blast radius  — vendor outages, lock collisions, resource exhaustion, etc.

# Bounds
## Out of scope                  — surfaces not supported, scaling ceiling, compliance gaps, non-goals
## Assumptions-that-could-flip
## Composes with / replaces

# Signals
## SLIs (leading)                 — or "deferred" + informally-tracked metrics
## Error budget burn (lagging)
## Audit checkpoints
## Capacity headroom triggers
## Kill criteria
```

### L3 (feature)

```
# Frame
## TL;DR
## Analog
## Reader & next action
## API surface fragment          — fenced code block: real function signature / CLI flags /
                                    request-response shape, exactly as implemented
## Consumer                      — who/what calls this (another spec ID or component)

# Substance
## What we know
## What we assume
## Contract
### Request shape
### Response shape
### Invariants                   — numbered, testable statements
### Error model                  — every failure path and what it returns/does
### Idempotency
### Versioning policy
## Performance budget            — p50/p95/p99 latency, throughput, cost per call
## Security model                — authN/authZ, tenant isolation, PII handling, rate limits
## Telemetry contract            — events emitted, sinks, linkage to L1 KPIs, AEAB-eligible cases
## Verifiers                     — tech lead / API council / security / QA sign-off owners
## Failure modes & blast radius  — one bullet per failure class with a concrete blast-radius sentence

# Bounds
## Out of scope                  — out-of-feature behaviors, capacity limits, deferred adjacent capabilities
## Assumptions-that-could-flip
## Composes with / replaces

# Signals
## Acceptance tests              — numbered Given/When/Then, concrete enough to become test cases
## Telemetry events tied to L1 KPIs
## AEAB cases                    — eval-framework hooks, or "N/A" + what a future one would record
## Kill criteria
```

A feature spec documenting internal prompt/template content (like a review-cycle state machine) inlines the actual prompt text under `## Prompt templates` between `Security model` and `Telemetry contract` — see `babysit-specs/L3-review-cycle.md` for the pattern. Only add this subsection if the feature's contract *is* a set of prompts/templates.

### L4 (task)

```
# Frame
## TL;DR
## Parent feature                — just the L3 ID, one line

# Substance
## Repro or Given/When/Then       — **Given** current / **when** trigger / **then** current behavior,
                                     then the same for the target behavior, then for the no-op case
## Affected surface               — files/functions/tests touched
## Implementation plan            — numbered steps; OMIT for small tasks, include for multi-step ones
## Validation steps               — numbered, concrete commands/checks a reviewer can run
## Reviewer                       — one name

# Bounds
## Out of scope
## Assumptions-that-could-flip    — lighter weight than L1-L3; 0-2 bullets is normal

# Signals
## Reviewer verification          — what the reviewer specifically checks for
## Regression test                — what test coverage this adds/extends
```

L4 has no `Composes with / replaces`, no `Analog`, no `Reader & next action`, and no `Kill criteria` — tasks are too small-scope for those.

## Conventions

**`[ASSUMPTION]` tag.** Every bullet under "What we assume" starts with `[ASSUMPTION]`, states the assumption, then `Flips if: <condition and what changes>`. When an assumption is later proven wrong, don't delete it — append `**Flipped YYYY-MM-DD:** <what happened>. Fix: <what changed>.` in place (see `babysit-specs/L3-mcp-resilience.md`'s two flipped assumptions for the pattern). This preserves the incident history instead of silently rewriting it.

**`[OPEN: <thing> — owner: <name>]` tag.** For information that's missing rather than assumed. Not yet used in this repo's specs (all current gaps are still `[ASSUMPTION]` pending sign-off), but it's the documented convention for unresolved items — use it when you genuinely don't know and need a named owner to close the gap, rather than guessing and tagging it `[ASSUMPTION]`.

**Cross-linking.** The first mention of another spec's ID in a page's body is a link to its file — `[ASF-FEAT-BUILDER](L3-builder.md)` — so the corpus stays navigable as a wiki (graph views, backlink tools, and plain clicking all work). Later mentions on the same page and all frontmatter IDs (`depends_on`, `parent_*`, `serves_l1`) stay plain text for parseability.

**Fit check.** Before drafting, ask: is a spec even the right artifact? Skip straight to a decision memo / RFC / spike instead if the input is a pure design philosophy with no implementation surface, needs cross-team consensus outside your control, is a research spike with no deliverable, or would duplicate an existing spec without obsoleting it. Every spec in this repo has `fit_check: passed` — none have hit this escalation yet, so there's no worked example of the escalation output; if you hit one, state the recommended alternative artifact and the one-sentence reason, and don't write spec files.

**Complexity scoring.** Every spec carries `total` / `band` / `drivers` / `scored_on`. This repo's specs use free-form driver names (`novelty`, `time_estimate`, `scope`, `external_integration`, `surface_span`) rather than a fixed dimension list, and only two totals appear (`2` → `trivial`, `3` → `moderate`) — **not enough examples here to pin down exact band thresholds or the full driver vocabulary.** Don't invent precise math; pick 2-4 drivers that plausibly explain the spec's difficulty, assign a total that's low for genuinely small/well-understood work, and ask the owner to confirm the band name if it matters for a `ready` gate decision.

**Status lifecycle.** Observed values: `review` (awaiting owner approval) and `ready` (approved, safe to build against). `draft` and `deprecated` aren't used yet in this repo but are reasonable to introduce if needed — confirm with the owner before treating a spec as `ready` without an explicit status change.

**Amending vs. new spec.** When a companion capability extends an existing product/system rather than standing alone, prefer amending the existing L1/L2 file's relevant prose (e.g. add a paragraph to `## What we know`, a new bullet to `## Composes with / replaces`) over creating a new L1/L2 or a separate amendments file. Record *why* in the index's Status section (see `babysit-specs/README.md`'s "Coordination note" style).

**Picking a prefix.** Pick one short, stable ID prefix per project (3-5 letters, no personal or employer-specific codenames) before writing the first spec — changing it later means touching every ID, every `depends_on`/`parent_*` reference, and the index table. This repo uses `ASF` (Autonomous Software Factory) for `babysit-specs/`. If you start a spec set for a different tool in this repo, pick a different prefix.

## Operations

The three workflows an agent runs against a spec corpus. Each one ends by updating `index.md` (if content changed) and appending a `log.md` entry.

### Ingest

A new ticket, feature idea, or owner decision arrives:

1. **Classify** the layer(s) it needs (L1–L4; a change can span layers).
2. **Fit-check** — is a spec the right artifact at all? (See Conventions.) If it trips, recommend the alternative artifact and stop.
3. **Confirm design decisions with the owner** before writing — sort the input into known / assumed / missing, ask about the missing and the decisions, don't invent.
4. **Draft or amend** — a new `L<n>-<slug>.md` page, or an amendment to an existing L1/L2 per the amending rule. Tag assumptions `[ASSUMPTION]` with flip conditions; tag genuine unknowns `[OPEN: ... — owner: ...]`.
5. **Update touched neighbors** — parent pages' `Composes with / replaces` / `What we know`, `depends_on` lists on affected siblings, cross-links.
6. **Update `index.md`** — new row, status change, or amended description.
7. **Append a `log.md` entry.**

A single ingest may touch several pages — that's expected; the point of the agent doing it is that all of them stay consistent in one pass.

### Query

Answering a question against the corpus:

1. Read `index.md` first to find relevant pages, then drill into them. Don't grep blind across the corpus when the index answers "which page".
2. Synthesize the answer with citations to specific specs/sections.
3. **File durable answers back.** If the answer produced a synthesis worth keeping — a comparison, a decision analysis, a cross-spec consistency finding — write it into the corpus as a page, add an index row, and log it. Explorations should compound in the corpus, not vanish into chat history.

Filed-back pages are **non-spec pages**: no `spec_type` frontmatter, free-form layout, indexed under the Plans & Amendments table (the same slot QA and security plans occupy). They never masquerade as L1–L4 specs.

### Lint

A periodic health check (run when asked, or opportunistically when working in a corpus that looks stale):

- **Spec↔implementation drift** — versions, flags, defaults, and behaviors named in specs vs. what the raw sources actually do now.
- **Stale `[ASSUMPTION]`/`[OPEN]` items** — flagged long ago, never resolved or flipped.
- **Orphan pages** — files in the directory missing from `index.md`, or pages nothing links to.
- **Dangling references** — spec IDs in `depends_on`/`parent_*`/body text that don't resolve to a file, and broken relative links.
- **Status staleness** — `review` specs whose blockers cleared, `ready` specs the implementation has since diverged from.

Lint **reports findings to the owner** — it doesn't silently fix content questions (drift and status changes are owner decisions; broken links and index omissions are safe to fix directly). The pass itself gets a log entry either way.

## Index and log

Two special files sit beside the spec pages. They serve different purposes: `index.md` is content-oriented (what exists), `log.md` is chronological (what happened).

> **Grandfathered corpus:** `babysit-specs/` predates these conventions — its `README.md` plays the index role, it has no `log.md`, and its spec-ID references are unlinked plain text. It stays that way until next migrated. Agents working in it fall back accordingly: treat `README.md` as the index, and git history as the log.

### index.md

The read-first retrieval entry point for the corpus — an agent answering a query or starting an ingest reads it before opening any spec. Updated on every ingest. Contents:

1. A one-line description of what the specs document.
2. A `## Specs` table: `Layer | File | Status | Description` (bold the file link; bold `**ready**` in the Status column to make ready specs scannable).
3. A `## Plans & Amendments` table for non-spec pages (security review checklists, QA test plans, filed-back analyses) that support the specs but aren't specs themselves.
4. A `## Status` section: current state per layer, explicit blockers to `ready` (strike through resolved ones with `~~...~~`), complexity/fit-check rollup.
5. `## Key Decisions Documented` — numbered list of the load-bearing decisions baked into the specs, so a reader doesn't have to open every file to find them.
6. `## Next Steps` — numbered, concrete, ends with "update status to ready" once blockers clear.

### log.md

Append-only, chronological, newest at the bottom. Every operation (ingest, amendment, filed-back query answer, lint pass, status change) appends one entry:

```markdown
## [YYYY-MM-DD] <op> | <title>

1-3 sentences: what happened and which pages were touched.
```

with `<op>` one of `ingest` / `amend` / `query` / `lint` / `status`. The consistent prefix keeps the log parseable with plain unix tools:

```bash
grep "^## \[" log.md | tail -5   # last 5 operations
```

Never edit or delete past entries — corrections get a new entry.

## What to bring to a new conversation

To draft or maintain specs matching this format, hand the assistant:

1. **This schema file.**
2. **The target corpus's `index.md` and the tail of its `log.md`** (or, for `babysit-specs/`, its `README.md` and recent git history) — so the agent knows what exists and what happened recently before touching anything.
3. **One sibling spec at the target layer** (or the closest layer if none exists yet) as a concrete style reference — `babysit-specs/L3-mcp-resilience.md` is the shortest complete L3.
4. **The project's ID prefix** and the parent IDs the new spec depends on (`parent_l1`/`parent_l2`/`parent_feature`/`serves_l1` as applicable) — don't guess these.
5. **What's actually known vs. assumed vs. missing** about the thing being specified — the assistant should sort your input into `What we know` / `What we assume` (tagged `[ASSUMPTION]` with a flip condition) / `[OPEN]` (tagged with an owner), not silently invent facts to fill gaps.
6. **Who the named sign-off owners are** for `Verifiers`/`Approvers`/`Reviewer` — these are real names in every existing spec, not roles.
7. **Confirmation before writing**, per this repo's standing instruction: don't let the assistant infer or assume design decisions and write them straight into a spec — surface the decision and get an explicit answer first, the same way the L3-builder decisions log ("Key Decisions Documented") shows real owner sign-off dates rather than assistant-assumed defaults.
