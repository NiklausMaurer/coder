# Design: Autonomous Implementation Loop

An autonomous loop that continuously drains `02-refined` stories of a target
repository via the nikos `/implement` process, parking anything that needs a
human, then polls for more. See [problem.md](problem.md) for the original
problem statement.

## Purpose

Continuously drain `kanban-board/02-refined` stories via `/implement` against any
repo that follows the nikos development process, parking anything that needs a
human, until the column is empty — then poll for more.

## Scope

- **Implement-only.** The loop only runs `/implement`. Refinement (`/refine`)
  stays a human, interactive task (it requires grilling the user).
- The "todo" in the original problem statement was a misnomer — the real source
  column is `02-refined`; `01-todo/` is the slice subdirectory *inside* a story
  folder, not a story-level column.

## Topology

- Runs on a **separate VM**.
- **One Docker container per target repo.** Scaling to more repos = run more
  containers. Strong isolation between repos; dead-simple loop logic.
- The container holds `claude` + `git`.
- **Volumes** persist across container restarts:
  - the **repo checkout** (avoids re-cloning each restart; the per-iteration
    hard-reset + pull keeps it clean anyway),
  - a **state file** (retry counts — so a quarantined poison-pill story stays
    quarantined across restarts).

## Configuration

- **Config = git remote URL + branch only** (branch defaults to `main`).
- Everything else — poll intervals, retry cap, kanban path, working dir — has
  sane built-in defaults, overridable via optional env vars.
- Goal: drop the loop onto any repo by configuring only the git repo (plus
  credentials).

## Authentication

- **Claude: subscription login** (`claude setup-token` on the VM). Draws from the
  Max/Pro plan's included usage — *not* a metered, separate `ANTHROPIC_API_KEY`
  API bill.
  - Caveat: subscription OAuth credentials on a headless box can expire and need
    re-login, and a busy loop eats into the same usage allowance as interactive
    Claude usage (heavy unattended runs may throttle day-to-day usage).
- **Git push: a scoped HTTPS Personal Access Token (PAT)** for the target repo,
  in the container's git credential store / env. Easy to rotate and revoke per
  repo.

## The Loop (each iteration)

1. **Clean the tree, then pull.**
   `git reset --hard && git clean -fd`, then `git pull`. The loop owns the
   isolated checkout, so it discards any crash leftovers. This is safe because
   `slice-lander` work is atomic-per-commit — anything uncommitted is incomplete
   and the slice re-runs from its `02-in-progress/` marker.

2. **Inspect the board to decide what to work on** (resume-then-drain,
   self-healing against crashes):
   - story in `kanban-board/03-in-progress/` → `claude -p "/implement <slug>"`
     (**resume** a story stranded by a crashed/killed previous run),
   - else story in `kanban-board/02-refined/` → `claude -p "/implement"`
     (no-slug form drains the lowest `NN-` story),
   - else **idle**.

3. **Run headless with `--dangerously-skip-permissions`.** Nobody is there to
   approve prompts; the VM/container is the real safety boundary (no prod creds,
   repo-scoped git token, disposable).

4. **Adaptive sleep.** Short sleep after doing work (drain the column fast);
   longer back-off when idle (poll for freshly-pushed human work). The board
   inspection in step 2 already tells the loop whether work exists, so no need to
   parse Claude's stdout.

5. **One story per pull.** Always work against the freshest remote state; simple
   loop; slightly more pull overhead, which is fine.

## Inherited Process Invariants

These come from the target repo's own `/implement`, `slice-lander`, and
`CLAUDE.md` and are not re-implemented by the loop:

- `/implement` commits **straight to the configured branch** and **pushes each
  landed slice** immediately (no PRs, no per-story branches).
- `/implement` **parks** a story to `kanban-board/04-user-verification/` when it
  hits a HITL slice, a slice-lander escalation, or a UI/manual-verification
  requirement.
- The no-slug `/implement` form picks the lowest `NN-` story in `02-refined/`, so
  parked stories in `04-user-verification/` are naturally skipped.

## Skills Source (the "follows the process" contract)

- The target repo **carries its own** `.claude/skills/{implement,refine}`,
  `.claude/agents/slice-lander`, `CLAUDE.md`, and `kanban-board/` columns.
- "Adheres to the same development process" *means* the repo contains these.
- The loop harness assumes they are present and just runs `/implement`. This
  keeps the harness fully repo-agnostic and tiny.

## Robustness

- **Retry cap → quarantine.** Track consecutive failed attempts per story slug in
  the (volume-persisted) state file. After N (≈3) crashes on the same
  in-progress story, stop resuming it.
  - Recommended quarantine action: **park the story to
    `kanban-board/04-user-verification/`** with a "crashed N×" note. A
    fast-crashing story genuinely needs a human, and this reuses the existing
    human-needed column instead of inventing a new board state — and it clears
    `03-in-progress/` so the loop can keep draining.
- **Per-run timeout.** Wrap `claude -p` in a timeout to kill hangs; a timed-out
  run counts toward the crash/retry cap.

## Notification

- **None active.** Parking and completion already commit + push to the board
  (parked → `04-user-verification/`, completed → folder deleted). Neither lingers
  in `02-refined/` or `03-in-progress/`, so the board itself is the source of
  truth. You check the repo/board when you want status.

## Deferred (v2)

- **HTTP observability endpoint** — expose current story, last iteration result,
  retry counts, and a board snapshot over HTTP. Not built in v1, but the Docker
  packaging and the structured, volume-persisted state file are chosen so this
  can be bolted on without re-architecting.
