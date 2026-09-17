---
name: accept-verification
description: Accept a story parked in kanban-board/04-user-verification/ after verifying it. If no slices remain in 01-todo/, the story is complete — delete it; otherwise move it back to 03-in-progress/ so /implement resumes the remaining slices. Use when the user says they verified a parked story, wants to accept/approve user verification, or complete a story sitting in the user-verification column. This is the human-side counterpart to /implement's park step (pass path only — failed verification is handled separately).
---

# Accept Verification

`/implement` parks every finished story in `kanban-board/04-user-verification/` and never
deletes one itself. This skill is the other half: the user's invocation **is** their
confirmation that the story checked out, and it is the only path that removes a completed
story from the board.

This is the **accept/pass path only.** If verification _failed_, don't run this — capture a
fix slice or a new story by hand and let `/implement` rework it.

## Process

### 1. Resolve the story (explicit slug required)

The caller must name the story by slug. Find `kanban-board/04-user-verification/<NN>-<slug>/`.
Do **not** guess and do **not** drain by lowest prefix. If the slug is missing, ambiguous,
or the story is not in `04-user-verification/`, stop and report — a story in `02-refined/`
or `03-in-progress/` is not awaiting verification.

### 2. Decide: complete, or more to come?

Look at the story's `01-todo/`:

- **Empty or absent** → everything is in `03-done/`. The story is complete → step 3a.
- **Holds slice files** → it parked on an escalation and has work left → step 3b.

Sanity check: a park should leave at least one slice in `03-done/`. If `03-done/` is also
empty, something is off — stop and report instead of deleting.

### 3a. Complete — remove the story

```sh
rm -rf kanban-board/04-user-verification/<NN>-<slug>/
git add -A
git commit -m "Remove completed <slug> story"   # + trailer below
git push
```

### 3b. Slices remain — return to in-progress and stop

`git mv` the **whole folder** back to `kanban-board/03-in-progress/<NN>-<slug>/` (next
prefix in that column — append, highest + 1 or `01`; gaps fine), commit ("Resumes `<slug>`
story after user verification") and push.

Then **stop** — do not auto-continue landing. Report the remaining slices from `01-todo/`
and that the user should run `/implement <slug>` (or let a draining loop pick it up).

### 4. Report

The branch that ran, the commit hash + subject (already pushed), and either that the story
is complete and removed, or where it now sits plus the `/implement <slug>` next step.

## Constraints

- **Accept-only.** This skill never handles a failed verification.
- **One story per invocation**, named by explicit slug.
- **Commit directly to the working branch** per this repo's convention, then push.
- Commit trailer for every commit this skill makes:

  <!-- coder:autofill commit-convention -->
  ```
  {{COMMIT_CONVENTION}}
  ```
  <!-- /coder:autofill -->

- Do not amend prior commits or rewrite history; do not pass `--no-verify`; do not run
  destructive git commands beyond the `rm -rf` of the completed story folder in step 3a.
