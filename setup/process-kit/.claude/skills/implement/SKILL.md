---
name: implement
description: Implement a refined story end-to-end — claim it (kanban-board/02-refined → 03-in-progress), run slice-lander subagents sequentially in dependency order, push each landed slice, pause for HITL slices or escalations, and delete the story when done. Use when the user wants to implement a story, land a refined story, or run the story end-to-end.
---

# Implement

Implement one refined story end-to-end by orchestrating `slice-lander` subagents. This skill runs in the **main session** — it spawns the subagents (a subagent cannot). When a story can't be finished without a human, it **parks** the whole story folder in `kanban-board/04-user-verification/` and notifies; resuming is a manual step (move it back to `03-in-progress/` and re-invoke). This lets a loop draining `02-refined/` park a blocked story and move on to the next one.

For unattended draining of the whole column, this skill is what a `/loop /implement` would call repeatedly.

> This skill is process-generic: it owns the kanban/slice mechanics only. All knowledge of *how to build and test this repo* lives in the `slice-lander` agent and your root `CLAUDE.md`.

## Process

### 1. Resolve and claim the story

Find the story by slug. If the caller gave no slug (e.g. a loop is draining the column), take the **lowest `NN-` prefix** in `kanban-board/02-refined/`.

- If the named story is in `kanban-board/04-user-verification/`, it is **parked awaiting human input** — report that and **stop**. Do **not** auto-resume it or auto-move it back; resuming is the manual step described below.
- If the named story is already in `kanban-board/03-in-progress/` (in progress from a previous run), **resume it in place** — skip the move, go to step 2.
- If it's in `02-refined/`, claim it: assign the next `NN-` prefix in `03-in-progress` (append — highest existing + 1, or `01`; gaps are fine), `git mv` the folder `02-refined/...` → `03-in-progress/...`, and commit the claim ("Starts `<slug>` story", with the trailer below). Don't push the claim on its own — the first landed slice's push carries it.
- If it's ambiguous or missing, stop and report.

(The no-slug "drain the column" form only ever picks the lowest `NN-` in `02-refined/`, so parked stories in `04-user-verification/` are naturally skipped by a draining loop.)

**Resuming a parked story is manual.** A human resolves the input the story needs, then `git mv`s the folder `04-user-verification/<NN>-<slug>/` → `03-in-progress/<MM>-<slug>/` (next `NN-` prefix in `03-in-progress/`; append, gaps fine) and re-invokes `/implement <slug>`, which resumes from `01-todo/`. (A story parked only for UI verification has nothing left in `01-todo/` on resume, so implement goes straight to deletion — see step 4.)

### 2. Plan the slice order

The remaining slices are the files in the story's `01-todo/` (already-landed ones are in `03-done/`). Order them by `NN-` prefix, respecting each slice's `Blocked by`. Run them **one at a time** on the shared working tree — never in parallel (slice-landers collide on one clone).

### 3. Run each slice in order

For each remaining slice:

- Read its `Type`:
  - **HITL** → **park and notify** (step 5) without attempting it. The slice file stays in `01-todo/`.
  - **AFK** → spawn a `slice-lander` subagent (Agent tool, `subagent_type: slice-lander`) pointed at the slice file's full path. Wait for it to finish.
- On the lander's result:
  - **Landed** (it committed and moved the file to `03-done/`): `git push`, then continue to the next slice.
  - **Escalated** a slice-level disagreement (slice is wrong, precondition false, invariant conflict): the lander has already exhausted its own bug-fixing — do **not** retry. The escalated slice file is sitting in the story's `02-in-progress/`; `git mv` it back to `01-todo/` so the story stays resumable, then **park and notify** (step 5), including the lander's escalation message.
- Track whether any lander flagged that **browser/manual UI verification** is still required (it does for any UI change) — needed at completion.

### 4. Complete the story

When every slice is in `03-done/`:

- **No UI/manual-verification flag from any landed slice** → delete the story: `rm -rf` the folder, commit "Remove completed `<slug>` story" (with trailer), `git push`. Done.
- **A UI/manual-verification flag exists** → **park and notify** (step 5): all slices are in `03-done/` (nothing in `01-todo/`), so the move carries an already-complete story. Notify the user that everything landed and pushed and the UI needs manual verification before deletion. After verifying, the human resumes per step 1 (move the folder back to `03-in-progress/`, re-invoke `/implement <slug>`); on that resume nothing remains in `01-todo/`, so this completion branch runs the deletion above. Keep that branch working.

### 5. Park and notify

Move the **whole story folder** out of `03-in-progress/` into `04-user-verification/` so a draining loop can move on: `git mv kanban-board/03-in-progress/<NN>-<slug>/ kanban-board/04-user-verification/<MM>-<slug>/` (assign the next `NN-` prefix in `04-user-verification/`; append — highest existing + 1, or `01`; gaps fine). The destination column already exists (it's tracked with a `.gitkeep`). Within the folder, landed slices stay in `03-done/` and any remaining slice(s) stay in `01-todo/`. Commit the move ("Parks `<slug>` story for user verification", with the trailer below) and `git push` so the parked state is on the remote.

Then notify the caller:

- **Where** it's parked: `kanban-board/04-user-verification/<MM>-<slug>/`.
- **Why** it parked — which kind of human input is needed: HITL slice `<NN>`, the lander's escalation message, or awaiting UI verification.
- **What's landed** so far (slices + commit hashes) — already pushed.
- **What you need** from the human to resume.

Resuming is manual (step 1): the human moves the folder back to `03-in-progress/` and re-invokes `/implement <slug>`, which resumes from `01-todo/`.

## Constraints

- **One story per invocation** (unless a caller explicitly loops over the column).
- **Sequential slice-landers only** — never run two on the shared clone.
- **Push each landed slice immediately**, so a parked story's completed work is already on the remote.
- For any commit this skill makes directly (claim, park, completion), follow this repo's commit convention and append its trailer:

  <!-- coder:autofill commit-convention -->
  ```
  {{COMMIT_CONVENTION}}
  ```
  <!-- /coder:autofill -->

- Do not amend prior commits or rewrite history; do not pass `--no-verify`; do not run destructive git commands.
