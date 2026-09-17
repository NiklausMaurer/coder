---
name: to-slices
description: Break a plan, spec, or the current conversation into tracer-bullet vertical slices, each declaring its blockers, written as slice files into a kanban story's 01-todo/. Use when the user wants to convert a plan into slices or sub-tasks, or break work down into smaller bits.
---

# To Slices

Break a plan into **tracer bullets**: vertical slices, each a narrow but COMPLETE path
through every layer (schema, API, UI, tests), each declaring the slices that **block** it.

## Process

### 1. Gather context

Work from whatever is already in the conversation. If the user passes a story reference,
look it up under `kanban-board/` — a story is a folder `NN-<slug>/` inside a column dir
(`01-backlog/`, `02-refined/`, `03-in-progress/`).

### 2. Explore the codebase

If you have not already explored it, do so now. Slice titles and bodies use the project's
domain vocabulary (`CONTEXT.md`, if there is one) and respect the ADRs in `docs/adr/` for
the area you're touching.

Look for **prefactoring** — "make the change easy, then make the easy change". Any
prefactoring slices lead the order.

### 3. Draft the slices

<vertical-slice-rules>
- Each slice cuts a narrow but COMPLETE path through every layer — vertical, NOT a
  horizontal slice of one layer
- A completed slice is demoable or verifiable on its own
- Each slice fits in a single fresh context window: a `slice-lander` subagent starts with
  none of this conversation, only the slice file and the repo
- Prefer many thin slices over few thick ones; prefactoring first
</vertical-slice-rules>

Every slice is implemented unattended — resolve any human-decision input during grilling,
not by deferring it into a slice. The user verifies the whole story once, after all slices
land (see `/implement`).

Give each slice its **blockers**: the slices that must complete before it can start. A
slice with no blockers can start immediately.

**Wide refactors are the exception to vertical slicing.** A wide refactor is one
mechanical change (rename a column, retype a shared symbol) whose **blast radius** fans
across the codebase, so a single edit breaks thousands of call sites and no vertical slice
can land green. Sequence it as **expand–contract** instead: _expand_ (add the new form
beside the old, nothing breaks), then _migrate_ in batches sized by blast radius — per
package, per directory — each batch its own slice blocked by the expand, each green
because the old form still exists, then _contract_ (delete the old form, blocked by every
batch).

### 4. Quiz the user

Present the breakdown as a numbered list. Per slice: **Title**, **Blocked by**, and **what
it delivers** (the end-to-end behaviour it makes work). Ask:

- Does the granularity feel right? (too coarse / too fine)
- Are the blockers real — does each slice only depend on what genuinely gates it?
- Should any slices be merged or split further?

For each slice, answer **"what can I demo when this is done?"** A slice with no answer is
a horizontal slice; re-cut it.

Iterate until the user approves.

### 5. Write the slice files

One file per approved slice, in implementation order, `NN-` prefixed, in the story's
`01-todo/` folder. Don't pre-create `02-in-progress/`/`03-done/` — git can't track empty
dirs; they're created on demand as slices move.

Slices must be **self-contained**. Cross-cutting context belonging to no single slice goes
in a `design.md` in the story folder.

Keep file paths and line numbers out of a slice body — they go stale fast. The one
exception: a snippet that encodes a decision more precisely than prose can (a schema, a
state machine, a type shape); inline the decision-rich part, not a working demo.

<slice-template>
## What to build

A concise description of this vertical slice. The end-to-end behaviour, from the user's
perspective — not a layer-by-layer implementation list.

## Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2

## Blocked by

- A reference to each blocking slice, or "None - can start immediately".

</slice-template>

Acceptance criteria must be able to **fail**. For each one, name the observation that
would show it false, and confirm it is false at the commit the lander starts from. A
criterion already true at the base commit, or one only another slice's work can satisfy,
grades nothing.

<!--
Attribution: adapted from `skills/engineering/to-tickets` in Matt Pocock's
"Skills For Real Engineers" (https://github.com/mattpocock/skills) — re-pointed to write
slice files into a kanban story folder instead of publishing issues to a tracker. Used
under the MIT License — Copyright (c) 2026 Matt Pocock.
-->
