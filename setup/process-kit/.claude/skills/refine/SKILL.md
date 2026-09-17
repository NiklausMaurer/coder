---
name: refine
description: Refine a backlog story into an implementable one — grill the problem, break it into slices (via to-slices), optionally capture a design.md, then promote the folder from kanban-board/01-backlog to 02-refined. Use when the user wants to refine a story, flesh out a backlog item, or get a story ready to implement.
---

# Refine

Take a story from `kanban-board/01-backlog/` and turn it into a refined story with defined
slices, ready for `/implement`. This skill orchestrates `grill-with-docs` and `to-slices`,
then promotes the story to the `02-refined` column.

This stage is interactive and human-driven by nature — the grilling needs the user.

## Process

### 1. Resolve the story

The caller names a story by slug (or backlog `NN-` prefix). Find it under
`kanban-board/01-backlog/NN-<slug>/`. If it's ambiguous, missing, or already in
`02-refined`/`03-in-progress`, stop and report — don't guess.

Read its `problem.md`.

### 2. Fetch before you grill

`git fetch && git log --oneline HEAD..origin/main` before the first question. The loop is a
second writer on this branch, and an interview long enough to be worth having is long
enough for it to land slices that change the code the new design rests on. If anything
landed in the area under discussion, re-read those files and tell the user plainly which
of their answers no longer holds — never quietly re-aim the design.

### 3. Grill

Invoke the `grill-with-docs` skill against the problem: interview the user down each
branch of the design tree, exploring the codebase to answer questions where you can, and
resolve decision-type human input **now** so the resulting slices can be implemented
unattended. It writes resolved vocabulary into `CONTEXT.md` and any qualifying decision
into `docs/adr/` as it goes; those files are part of this story's commit.

### 4. Slice

Fetch again (step 2's reasoning applies twice — the interview took time), then invoke the
`to-slices` skill to break the refined understanding into tracer-bullet vertical slices.
It writes the slice files into the story's `01-todo/`, `NN-` prefixed in implementation
order.

### 5. Capture design (optional)

If the grilling surfaced cross-cutting decisions, constraints, or an approach that don't
belong to any single slice, write a concise `design.md` in the story folder. Skip it when
the self-contained slices already say everything.

### 6. Promote to refined

Story folders are ordered within their column by a two-digit `NN-` prefix (priority —
lowest is next). Assign the next `02-refined` prefix by **appending**: highest existing
`NN-` among `kanban-board/02-refined/*/` plus one (zero-padded), or `01` if empty. Gaps are
fine — never renumber. Re-read the column right before assigning: the loop drains it
underneath you.

Then `git mv` the story folder from `kanban-board/01-backlog/<old-NN>-<slug>/` to
`kanban-board/02-refined/<new-NN>-<slug>/`.

### 7. Commit and push

Stage the move, the slice files, and any `design.md`/`CONTEXT.md`/ADR the grilling
produced, and commit. Match the project's commit style (`git log --oneline -10`), e.g.
"Refines `<slug>` story". Append the trailer:

<!-- coder:autofill commit-convention -->
```
{{COMMIT_CONVENTION}}
```
<!-- /coder:autofill -->

Commit directly to the working branch per this repo's convention, then push — an unpushed
commit is destroyed by the loop's next `git reset --hard`.

### 8. Report

Tell the user the refined path, the slices created, whether a `design.md` was written, any
`CONTEXT.md`/ADR changes, and the next step: `/implement <slug>` to land it.
