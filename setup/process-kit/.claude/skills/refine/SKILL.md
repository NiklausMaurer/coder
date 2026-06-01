---
name: refine
description: Refine a backlog story into an implementable one — grill the problem, break it into slices (via to-slices), optionally capture a design.md, then promote the folder from kanban-board/01-backlog to 02-refined. Use when the user wants to refine a story, flesh out a backlog item, or get a story ready to implement.
---

# Refine

Take a story from `kanban-board/01-backlog/` and turn it into a refined story with defined slices, ready for `/implement`. This skill orchestrates the existing `grill-me` and `to-slices` skills, then promotes the story to the `02-refined` column.

This stage is interactive and human-driven by nature — the grilling needs the user.

## Process

### 1. Resolve the story

The caller names a story by slug (or backlog `NN-` prefix). Find it under `kanban-board/01-backlog/NN-<slug>/`. If it's ambiguous, missing, or already in `02-refined`/`03-in-progress`, stop and report — don't guess.

Read its `problem.md`.

### 2. Grill

Invoke the `grill-me` skill against the problem to reach shared understanding — interview the user down each branch of the design tree, exploring the codebase to answer questions where you can. Resolve decision-type human input **now**, so the resulting slices can be implemented unattended.

### 3. Slice

Invoke the `to-slices` skill to break the refined understanding into tracer-bullet vertical slices. It writes the slice files into the story's `01-todo/` (creating `01-todo/`, `02-in-progress/`, `03-done/`), records each slice's `Type` (AFK/HITL), and orders them with `NN-` prefixes.

Prefer **AFK** slices. Only leave a slice **HITL** when it genuinely needs a human mid-stream — the implementer will pause there.

### 4. Capture design (optional)

If the grilling surfaced cross-cutting decisions, constraints, or an approach that don't belong to any single slice, write a concise `design.md` in the story folder. Skip it when the self-contained slices already say everything — it's optional.

### 5. Promote to refined

Story folders are ordered within their column by a two-digit `NN-` prefix (priority — lowest is next). Assign the next `02-refined` prefix by **appending**: highest existing `NN-` among `kanban-board/02-refined/*/` plus one (zero-padded), or `01` if empty. Gaps are fine — never renumber.

Then `git mv` the story folder from `kanban-board/01-backlog/<old-NN>-<slug>/` to `kanban-board/02-refined/<new-NN>-<slug>/`.

### 6. Commit and push

Stage the move and the new slice files (and `design.md` if written) and commit. Match the project's commit style (`git log --oneline -10`), e.g. "Refines `<slug>` story". Append the trailer:

<!-- coder:autofill commit-convention -->
```
{{COMMIT_CONVENTION}}
```
<!-- /coder:autofill -->

Commit directly to the working branch per this repo's convention, then push.

### 7. Report

Tell the user the refined path, the slices created (with their Type), whether a `design.md` was written, and the next step: `/implement <slug>` to land it.
