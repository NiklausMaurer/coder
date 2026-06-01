---
name: accept-verification
description: Accept a story parked in kanban-board/04-user-verification/ after its UI has been manually verified. If no slices remain in the story's 01-todo/, the verified slice was the last one — delete the completed story; otherwise move the story back to 03-in-progress/ so /implement resumes the remaining slices. Use when the user says they verified a parked story, wants to accept/approve user verification, mark a UI slice verified, or complete a story sitting in the user-verification column. This is the human-side counterpart to /implement's park step (pass path only — failed verification is handled separately).
---

# Accept Verification

`/implement` parks a story in `kanban-board/04-user-verification/` when a landed UI slice needs a human to eyeball it in the browser. This skill is the resume: the user's invocation **is** their confirmation that the UI checked out. It then finishes the parked story — deleting it if nothing remains, or returning it to the in-progress flow if more slices are queued.

This is the **accept/pass path only.** If verification *failed* (you found a bug), don't run this — capture a fix slice or a new story by hand and let `/implement` rework it.

## Process

### 1. Resolve the story (explicit slug required)

The caller must name the story by slug. Find the matching folder in `kanban-board/04-user-verification/<NN>-<slug>/`. Do **not** guess and do **not** drain by lowest prefix — if the slug is missing, ambiguous (multiple matches), or the named story is **not** in `04-user-verification/`, stop and report. (A story still in `02-refined/` or `03-in-progress/` is not awaiting verification — say so.)

### 2. Decide: last slice, or more to come?

Look at the story's `01-todo/` directory:

- **Empty or absent** → the verified slice was the **last** slice (everything else is already in `03-done/`). Go to step 3a.
- **Contains one or more slice files** → there is **more to do**. Go to step 3b.

Sanity check: a verification park should have at least one slice in `03-done/`. If `03-done/` is also empty, something is off — stop and report instead of deleting.

### 3a. Last slice — complete and remove the story

The story is done. Delete the whole folder, commit, push:

```sh
rm -rf kanban-board/04-user-verification/<NN>-<slug>/
git add -A
git commit -m "Remove completed <slug> story"   # + trailer below
git push
```

### 3b. Slices remain — return to in-progress and stop

Move the **whole folder** back to `03-in-progress/` so `/implement` can resume from `01-todo/`. Assign the next `NN-` prefix in `03-in-progress/` (highest existing + 1, or `01`; gaps fine):

```sh
git mv kanban-board/04-user-verification/<NN>-<slug>/ kanban-board/03-in-progress/<MM>-<slug>/
git commit -m "Resumes <slug> story after UI verification"   # + trailer below
git push
```

Then **stop** — do not auto-continue landing. Report that the remaining slices (list them from `01-todo/`) are ready and the user should run `/implement <slug>` (or let a draining loop pick it up).

### 4. Report

State which branch ran, the commit hash + subject (already pushed), and:

- **3a:** the story is complete and removed.
- **3b:** where it now sits (`03-in-progress/<MM>-<slug>/`), which slices remain in `01-todo/`, and the `/implement <slug>` next step.

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

- Do not amend prior commits or rewrite history; do not pass `--no-verify`; do not run destructive git commands beyond the `rm -rf` of the completed story folder in step 3a.
