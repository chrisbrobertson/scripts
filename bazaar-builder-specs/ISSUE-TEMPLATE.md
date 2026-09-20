# Bazaar issue template

Non-spec page. The body layout the issue worker normalises every issue into (BZR-FEAT-ISSUE-WORKER phase 2) and the layout the human is encouraged to use up front. Ship as `.github/ISSUE_TEMPLATE/bazaar.md` in managed repos; the worker rewrites bodies that do not follow it and keeps the original text in the details block.

```markdown
## Problem
<what is wrong or missing, observable from the outside>

## Desired outcome
<what is true when this is done>

## Acceptance criteria
- [ ] <testable statement>
- [ ] <testable statement>

## Scope
In: <...>
Out: <...>

## Type
bug | feature      <!-- also set the `bug` or `enhancement` label; label wins if they disagree -->

## Links
Specs: <spec IDs and paths; "none yet" until the approval sweep fills it>
Related: #<n> ...

<details><summary>Original report</summary>

<verbatim original body, untouched>

</details>
```

Rules the worker follows when normalising:
- Never delete or paraphrase the original; move it into the details block verbatim.
- Fill only what the issue, its comments, linked issues, or the repo establish. Anything else becomes a numbered question, not a filled field.
- `Type` is taken from the label when present.
