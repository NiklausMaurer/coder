---
name: add-story
description: Create a new story in the kanban-board backlog — kanban-board/01-backlog/NN-<slug>/ containing just problem.md. Use when the user wants to add a new story, start a new story, or capture a new problem to refine and implement later.
---

# Add Story

Create a new backlog story under `kanban-board/01-backlog/NN-<slug>/`. A backlog story is just a problem statement — slices are added later by `/refine`.

## What gets created

```
kanban-board/01-backlog/NN-<slug>/
└── problem.md
```

No slice subdirs (`01-todo`, etc.) — `/refine` creates those when the story is refined.

## Process

### 1. Resolve the slug

The slug must be **kebab-case** (lowercase `a-z`, digits `0-9`, and dashes `-` only — no spaces, no uppercase). Examples: `db-schema-migrations`, `payment-retry-flow`.

- If the user passed a slug as an argument, validate it. Reject anything that doesn't match `^[a-z0-9]+(-[a-z0-9]+)*$` and ask them to fix it.
- If they passed a free-text title (e.g. "DB schema migrations"), do NOT silently slugify it. Show them the kebab-case form you'd use and confirm before proceeding.
- If no slug was provided at all, ask for one.

### 2. Resolve the problem statement

The problem statement goes verbatim into `problem.md`. It's usually 1–3 sentences explaining _why_ the story exists — the user-facing problem or motivation, not the implementation.

- If the user passed a problem description, use it as-is.
- If not, ask for it. Don't invent one.

### 3. Check preconditions

Before creating anything:

- The repo must contain `kanban-board/01-backlog/` (the backlog column). If missing, stop and tell the user — the project may not use this convention.
- No story with this slug may already exist in **any** column. Check `kanban-board/*/NN-<slug>/` (the `NN-` prefix varies, so match on the `-<slug>` suffix). If one exists, stop and surface the existing path rather than creating a duplicate.

### 4. Resolve the prefix

Story folders are ordered within their column by a two-digit `NN-` prefix (priority order — lowest is next). Assign the backlog prefix by **appending**: take the highest existing `NN-` among `kanban-board/01-backlog/*/` and add one, zero-padded to two digits. If the backlog is empty, start at `01`.

Gaps are fine — never renumber existing folders to close them.

### 5. Create the scaffold

```sh
mkdir -p kanban-board/01-backlog/NN-<slug>
```

Then write `problem.md` with the problem statement as the entire file body (no frontmatter, no headings — match the existing convention).

### 6. Commit the story

Always commit the new story before reporting — one commit per `/add-story` invocation.

Commit **only** the new `problem.md`, using a path-limited commit so unrelated staged or in-flight changes are never swept in:

```sh
git add kanban-board/01-backlog/NN-<slug>/problem.md
git commit kanban-board/01-backlog/NN-<slug>/problem.md -m "Adds <slug> backlog story"
```

Commit directly to the working branch per this repo's convention (the loop model is commit-per-change on the branch, not feature branches). Do not push.

### 7. Report

Tell the user the path that was created and the next step: `/refine <slug>` to grill the problem and break it into slices.

## Example

User: `/add-story payment-retry-flow Failed Stripe charges currently surface as a generic 500. We need a retry path so transient failures don't lose the order.`

Result (assuming the backlog already holds `01-...` and `02-...`):

```
kanban-board/01-backlog/03-payment-retry-flow/
└── problem.md          # the two-sentence description verbatim
```
