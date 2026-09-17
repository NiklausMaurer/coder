---
name: implement
description: Implement a refined story end-to-end — claim it (kanban-board/02-refined → 03-in-progress), run slice-lander subagents sequentially in dependency order, push each landed slice, pause on escalations, and park the completed story for user verification. Use when the user wants to implement a story, land a refined story, or run the story end-to-end.
---

# Implement

Implement one refined story end-to-end by orchestrating `slice-lander` subagents. This
skill runs in the **main session** — it spawns the subagents (a subagent cannot). Slices
are landed unattended; **every** finished story is then **parked** in
`kanban-board/04-user-verification/` for the user to verify before deletion (a slice-lander
cannot check UI behavior, and the user verifies every story regardless). A story is also
parked early if a slice-lander escalates a disagreement it can't resolve. Parking moves the
whole story folder and notifies; resuming is a manual step. This lets a loop draining
`02-refined/` park a story and move on to the next one.

For unattended draining of the whole column, this skill is what a `/loop /implement` would
call repeatedly.

> This skill is process-generic: it owns the kanban/slice mechanics only. All knowledge of
> *how to build and test this repo* lives in the `slice-lander` agent and your root
> `CLAUDE.md`.

**Column prefixes.** Story folders are ordered within their column by a two-digit `NN-`
prefix (priority — lowest is next). Every move in this skill **appends**: highest existing
`NN-` in the destination column plus one (zero-padded), or `01` if it's empty. Gaps are
fine — never renumber.

## Process

### 1. Resolve and claim the story

Find the story by slug. If the caller gave no slug (e.g. a loop is draining the column),
take the **lowest `NN-` prefix** in `kanban-board/02-refined/`.

- In `kanban-board/04-user-verification/` → it is **parked awaiting a human**. Report that
  and **stop**. Do not auto-resume or auto-move it.
- In `kanban-board/03-in-progress/` (from a previous run) → **resume it in place**: skip
  the move, go to step 2.
- In `02-refined/` → claim it: `git mv` the folder to `03-in-progress/<NN>-<slug>/` and
  commit the claim ("Starts `<slug>` story"). Don't push the claim on its own — the first
  landed slice's push carries it.
- Ambiguous or missing → stop and report.

(The no-slug "drain the column" form only ever picks the lowest `NN-` in `02-refined/`, so
parked stories are naturally skipped by a draining loop.)

**Resuming a parked story is manual, and which path depends on why it parked:**

- **Awaiting verification** (the normal completion case — nothing left in `01-todo/`): the
  user verifies, then accepts with `/accept-verification <slug>`, which deletes the
  finished story. `/implement` is not re-invoked.
- **Escalation** (slices still in `01-todo/`): a human resolves the disagreement, `git mv`s
  the folder back to `03-in-progress/<NN>-<slug>/` and re-invokes `/implement <slug>`,
  which resumes from `01-todo/`.

### 2. Plan the slice order

The remaining slices are the files in the story's `01-todo/` (already-landed ones are in
`03-done/`). Order them by `NN-` prefix, respecting each slice's `Blocked by`. Run them
**one at a time** on the shared working tree — never in parallel (slice-landers collide on
one clone).

### 3. Run each slice in order

For each remaining slice, spawn a `slice-lander` subagent (Agent tool,
`subagent_type: slice-lander`) pointed at the slice file's full path and wait for it to
finish. Set the Agent `description` to `Land slice <NN> of <story>: <slice title>` — the
slice's `NN-` prefix, the story slug, and the slice's own title (its file heading, falling
back to its `<slug>`). The coder loop surfaces this `description` verbatim in its logs, so
naming the slice is what makes each landed slice legible there. On its result:

- **Landed** (it committed and moved the file to `03-done/`): `git push`, then continue to
  the next slice.
- **Escalated** a slice-level disagreement (slice is wrong, precondition false, invariant
  conflict): the lander has already exhausted its own bug-fixing — do **not** retry. The
  escalated slice file is sitting in the story's `02-in-progress/`; `git mv` it back to
  `01-todo/` so the story stays resumable, then **park and notify** (step 5), including the
  lander's escalation message.

### 4. Complete the story

When every slice is in `03-done/`, the story is implemented but **not done** — the user
verifies every story before it's deleted. **Park and notify** (step 5): all slices are in
`03-done/` (nothing in `01-todo/`), so the move carries an already-complete story awaiting
verification. Notify the user that everything landed and pushed and the story needs
verification before deletion. Deletion happens when the user accepts the verification
(`/accept-verification <slug>`), not here.

### 5. Park and notify

Move the **whole story folder** out of `03-in-progress/` into
`kanban-board/04-user-verification/<NN>-<slug>/` so a draining loop can move on. The
destination column already exists (tracked with a `.gitkeep`). Within the folder, landed
slices stay in `03-done/` and any remaining slice stays in `01-todo/`. Commit the move
("Parks `<slug>` story for user verification") and `git push` so the parked state is on the
remote.

Then notify the caller:

- **Where** it's parked: `kanban-board/04-user-verification/<NN>-<slug>/`.
- **Why** it parked — either the story is complete and **awaiting user verification**, or a
  slice-lander **escalated** (include its message and which slice).
- **What's landed** so far (slices + commit hashes) — already pushed.
- **What you need** from the human to resume.

## Constraints

- **One story per invocation** (unless a caller explicitly loops over the column).
- **Sequential slice-landers only** — never run two on the shared clone.
- **Push each landed slice immediately**, so a parked story's completed work is already on
  the remote.
- For any commit this skill makes directly (claim, park), follow this repo's commit
  convention and append its trailer:

  <!-- coder:autofill commit-convention -->
  ```
  {{COMMIT_CONVENTION}}
  ```
  <!-- /coder:autofill -->

- Do not amend prior commits or rewrite history; do not pass `--no-verify`; do not run
  destructive git commands.
