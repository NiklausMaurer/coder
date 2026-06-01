---
name: to-slices
description: Break a plan, spec, or PRD into independently-grabbable slices using tracer-bullet vertical slices. Use when user wants to convert a plan into slices or sub-tasks or break down work into smaller bits.
---

# To Slices

Break a plan into independently-grabbable slices using vertical slices (tracer bullets).

## Process

### 1. Gather context

Work from whatever is already in the conversation context. If the user passes a story reference as an argument, look it up under `kanban-board/` — a story is a folder `NN-<slug>/` inside one of the column dirs (`01-backlog/`, `02-refined/`, `03-in-progress/`).

### 2. Explore the codebase (optional)

If you have not already explored the codebase, do so to understand the current state of the code. Slice titles and descriptions should use the project's domain glossary vocabulary, and respect ADRs in the area you're touching.

### 3. Draft vertical slices

Break the plan into **tracer bullet** slices. Each slice is a thin vertical slice that cuts through ALL integration layers end-to-end, NOT a horizontal slice of one layer.

Slices may be 'HITL' or 'AFK'. HITL slices require human interaction, such as an architectural decision or a design review. AFK slices can be implemented and merged without human interaction. Prefer AFK over HITL where possible.

<vertical-slice-rules>
- Each slice delivers a narrow but COMPLETE path through every layer (schema, API, UI, tests)
- A completed slice is demoable or verifiable on its own
- Prefer many thin slices over few thick ones
</vertical-slice-rules>

### 4. Quiz the user

Present the proposed breakdown as a numbered list. For each slice, show:

- **Title**: short descriptive name
- **Type**: HITL / AFK
- **Blocked by**: which other slices (if any) must complete first
- **User stories covered**: which user stories this addresses (if the source material has them)

Ask the user:

- Does the granularity feel right? (too coarse / too fine)
- Are the dependency relationships correct?
- Should any slices be merged or split further?
- Are the correct slices marked as HITL and AFK?

Iterate until the user approves the breakdown.

### 5. Store the slices in the story folder

For each approved slice, create a separate file. Use the template below.
Order the slices by implementation order. Prefix the file names with numbers.
Put the file in the `01-todo` folder inside the story folder (and add empty `02-in-progress` and `03-done` folders if they don't exist yet.)

Slices must be **self-contained** (Cross-cutting context that doesn't belong to a single slice can go in a `design.md` in the story folder instead.).

Record each slice's **Type** (`AFK` or `HITL`). HITL means the slice consists of configuration and/or verification that must be done by a human; the implementer pauses there. Try to avoid HITL.

<slice-template>
## What to build

A concise description of this vertical slice. Describe the end-to-end behavior, not layer-by-layer implementation.

## Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

## Type

`AFK` or `HITL`.

## Blocked by

- A reference to the blocking ticket (if any)

Or "None - can start immediately" if no blockers.

</slice-template>

<!--
Attribution: adapted from `skills/engineering/to-issues` in Matt Pocock's
"Skills For Real Engineers" (https://github.com/mattpocock/skills) — re-pointed to
write slice files into a kanban story folder instead of publishing issues to a
tracker. Used under the MIT License — Copyright (c) 2026 Matt Pocock.
-->

