# How this works — the kanban story process

This repo develops features as a **board of stories** that flow left-to-right through
the columns in this directory. Most of the flow can run **unattended**: the
[coder](https://github.com/NiklausMaurer/coder) loop repeatedly runs `/implement` to
drain refined stories, pausing only when a human is genuinely needed. If you're new
here, this page is the whole mental model.

## The unit of work: stories and slices

- A **story** is a folder `kanban-board/<column>/NN-<slug>/`. The `NN-` is a two-digit
  priority prefix (lowest = next); the `<slug>` is kebab-case. A fresh story is just a
  `problem.md` — a sentence or two on *why* it exists.
- **Refining** a story breaks it into **slices**: thin **tracer-bullet vertical slices**
  that each cut end-to-end through every layer (schema → API → UI → tests) and are
  demoable on their own. Many thin slices beat a few thick ones. Slices live as files
  inside the story folder, moving through sub-directories `01-todo/ → 02-in-progress/ →
  03-done/` as they're built.
- Each slice is typed **AFK** or **HITL**:
  - **AFK** ("away from keyboard") — an agent can build and land it unattended.
  - **HITL** ("human in the loop") — needs a person (a design call, a manual config, a
    UI eyeball). The implementer pauses rather than guessing. Prefer AFK; reserve HITL
    for what truly needs you.

## The columns (left → right)

| Column | Meaning | Who moves it on |
|---|---|---|
| `01-backlog/` | Captured problems, not yet refined. Just `problem.md`. | `/refine` (you) |
| `02-refined/` | Sliced and ready to build. **This is the loop's inbox.** | `/implement` (loop) |
| `03-in-progress/` | A story being landed slice by slice. | `/implement` (loop) |
| `04-user-verification/` | Parked — needs a human (a HITL slice, an escalation, or a UI check). | `/accept-verification` (you) |

A finished story is **deleted** from the board (its work lives in git history), so the
board only ever shows outstanding work.

## The skills, and who runs them

Two halves: a **human-driven** half that fills and unblocks the board (runs on your
machine, interactively), and an **autonomous** half that drains it (the loop).

**You, to fill the queue:**

1. `/add-story <slug> <problem>` — create a backlog story (`01-backlog/NN-<slug>/problem.md`).
2. `/refine <slug>` — interactive. It runs `/grill-me` to interrogate the problem until
   the design is settled, then `/to-slices` to cut it into AFK/HITL slices, then promotes
   the story to `02-refined/`. **Resolve all the decision-type questions here** — that's
   what lets the build run unattended afterwards.

**The loop, to drain the queue** (you can also run these by hand):

3. `/implement [<slug>]` — claims the lowest story in `02-refined/` (or the named one),
   moves it to `03-in-progress/`, and lands its slices **one at a time** by spawning a
   `slice-lander` subagent per slice, pushing after each. If it hits a HITL slice, an
   escalation, or a UI slice that needs eyeballing, it **parks the whole story** in
   `04-user-verification/` and moves on. When every slice is done (and no UI check is
   pending) it deletes the story.
4. `slice-lander` (a subagent, not a slash command) — lands **exactly one** slice
   end-to-end: implements it, runs this repo's verification gate (typecheck/lint/test/
   build), commits, and moves the slice file to `03-done/`. It never pushes and never
   starts a second slice.

**You, to unblock:**

5. `/accept-verification <slug>` — the accept path for a parked story. Running it **is**
   your confirmation that the UI checked out: it deletes the story if nothing remains, or
   moves it back to `03-in-progress/` so the loop resumes the rest. (Verification
   *failed*? Don't run this — capture a fix slice or new story and let `/implement`
   rework it.)

```
/add-story ──▶ 01-backlog ──/refine──▶ 02-refined ──/implement──▶ 03-in-progress ──▶ (done, deleted)
                                                          │                ▲
                                              parks blocker│                │/accept-verification
                                                          ▼                │
                                                 04-user-verification ──────┘
```

## Two invariants worth knowing

- **Work lands as commits directly on the working branch — no feature branches or PRs.**
  Each slice is its own atomic commit, pushed immediately. This is what lets the loop
  treat its checkout as disposable (it hard-resets to the remote each iteration): any
  uncommitted state is just an incomplete slice that re-runs.
- **The board is the source of truth, not an agent's chatter.** What column a story sits
  in *is* its status. A story still in `03-in-progress/` after a run is a failed attempt;
  gone means completed or cleanly parked.

> The repo-specific knowledge — how to build and test this repo, its architecture rules,
> its commit convention — lives in `.claude/agents/slice-lander.md` and the root
> `CLAUDE.md`, not here. This page is the process; those are the specifics.
