---
name: add-story
description: Create a new story in the kanban-board backlog — kanban-board/01-backlog/NN-<slug>/ containing just problem.md. Use when the user wants to add a new story, start a new story, or capture a new problem to refine and implement later.
---

# Add Story

Create a backlog story at `kanban-board/01-backlog/NN-<slug>/problem.md`. A backlog story
is only a problem statement — `/refine` adds the slices and the `01-todo/` subdir later.

## Process

### 1. Resolve the slug

The slug is **kebab-case**: `^[a-z0-9]+(-[a-z0-9]+)*$`, e.g. `payment-retry-flow`.

- Slug passed as an argument → validate it; reject anything that doesn't match and ask.
- Free-text title passed (e.g. "DB schema migrations") → show the kebab-case form you'd
  use and confirm before proceeding. Never silently slugify.
- Nothing passed → ask.

### 2. Resolve the problem statement

Usually 1–3 sentences on _why_ the story exists — the user-facing problem, not the
implementation. Use what the user passed verbatim; if they passed none, ask. Don't invent
one.

### 3. Check preconditions

- `kanban-board/01-backlog/` must exist. If not, stop — the project may not use this
  convention.
- No story with this slug may exist in **any** column: check `kanban-board/*/NN-<slug>/`,
  matching on the `-<slug>` suffix since the `NN-` prefix varies. If one exists, stop and
  surface its path rather than creating a duplicate.

### 4. Create and commit

Assign the next backlog `NN-` prefix by appending (highest existing in
`kanban-board/01-backlog/*/` plus one, zero-padded, or `01` if empty; gaps are fine, never
renumber), then write `problem.md` with the statement as the entire file body — no
frontmatter, no headings.

Commit **path-limited**, so unrelated staged or in-flight changes are never swept in (the
loop's uncommitted slice work may be sitting in the tree):

```sh
git add kanban-board/01-backlog/NN-<slug>/problem.md
git commit kanban-board/01-backlog/NN-<slug>/problem.md -m "Adds <slug> backlog story"
```

One commit per invocation, directly on the working branch per this repo's convention (the
loop model is commit-per-change on the branch, not feature branches). Push it if the loop
is running against this repo — its per-iteration `git reset --hard` destroys unpushed
commits.

### 5. Report

The path created, and the next step: `/refine <slug>` to grill the problem and slice it.
