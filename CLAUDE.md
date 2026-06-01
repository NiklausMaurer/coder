# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`coder` is an autonomous loop — pure Bash, no application runtime — that drains the
`kanban-board/02-refined` column of a *target* repo by repeatedly running that repo's
own `/implement` process, parking anything that needs a human, then polling for more.
Ships as a Docker image, one container per target repo.

The harness is deliberately tiny and **repo-agnostic**: it owns none of the development
process. The `/implement` skill, `slice-lander` agent, `CLAUDE.md`, and `kanban-board/`
columns all live in the *target* repo (the nikos process, see `../nikos`). This loop just
ensures a checkout and runs `claude -p "/implement"` inside it. Do not add process logic
(refinement, slice mechanics, board conventions) to the loop (`bin/`) — it belongs in the
target repo.

The one place process artifacts live here is `setup/process-kit/` — *templates* of the
`implement` skill and `slice-lander` agent used to onboard a brand-new target repo that
doesn't have them yet. That is a one-time scaffolder (`setup/init-target.sh` copies them
*into* the target repo, to be committed there), explicitly **not** part of the loop: `bin/`
never reads `setup/`. Keep it that way — the templates are a convenience for bootstrapping,
not runtime behavior. See `setup/README.md`.

## Commands

```sh
# Run the test suites (self-contained bash harnesses, no bats needed)
bash test/run-once.test.sh
bash test/loop.test.sh
bash test/init-target.test.sh   # setup/init-target.sh scaffold path

# Run a single test: source the file's functions, then call one test by name.
# (Tests are bash functions named test_*; the runner block at the bottom lists them.)

# Run the loop / one-shot locally (needs a real target repo + Claude auth)
TARGET_REPO=https://github.com/you/repo.git bin/run-once.sh
TARGET_REPO=https://github.com/you/repo.git bin/loop.sh

# Build & run the container (config via .env — copy from .env.example)
docker compose up -d --build
docker compose logs -f
```

There is no build step, linter, or package manager — the deliverable is the Bash scripts
themselves. Validate changes by running the two test suites.

## Architecture

Three scripts in `bin/`, layered — each sources the one below and re-points `log()`:

- **`run-once.sh`** — the innermost unit. `ensure_checkout()` (clone-or-fast-forward with
  dirty-tree hygiene) + `run_implement([slug])` (one `timeout`-bounded `claude -p` run).
  Exits with the `/implement` run's status. Sourceable: `main` only runs when executed
  directly (`BASH_SOURCE`/`$0` guard), so tests can source its functions.
- **`loop.sh`** — sources `run-once.sh` and wraps it in the iteration loop: pull → inspect
  board (**resume-then-drain**) → work-or-idle → adaptive sleep. Owns the retry-cap →
  quarantine state machine.
- **`docker-entrypoint.sh`** — container only. Wires credentials from env (git PAT into the
  credential store, committer identity, `safe.directory '*'`), then `exec`s `loop.sh`. Kept
  separate so the loop stays host-agnostic and testable outside Docker.

### Two invariants that drive the design

1. **The board is the work/idle signal, never Claude's stdout.** Each iteration inspects
   directories under `kanban-board/` to decide what to do and whether a run succeeded.
   `03-in-progress/<slug>` still present after a run = a failed attempt; gone = completed
   or cleanly parked.

2. **The checkout is disposable and loop-owned.** Every iteration does `git reset --hard`
   + `git clean -fd` before pulling. This is safe *only because* slice work is
   atomic-per-commit — uncommitted state is always an incomplete slice that re-runs. Never
   add logic that rewrites committed history (no rebase/amend/force-push).

### Retry-cap → quarantine

Consecutive failed resume attempts per slug are tallied in `STATE_FILE` (a flat
`slug<TAB>count` table) which lives on its **own volume**, outside the checkout, so counts
survive both the per-iteration tree reset and a process restart. A clean park/completion
clears the count; hitting `MAX_RETRIES` quarantines the story by `git mv`-ing it to
`04-user-verification/` with a `QUARANTINE.md` note (reusing the human-needed column
rather than inventing a new board state).

## Testing conventions

Tests build a real fixture git repo (bare remote + seeded `main` with a kanban board) and
stub the `claude` CLI via `CLAUDE_BIN` / `PATH` with a fake `/implement` that commits and
pushes — so the runner/loop are exercised end-to-end against real git, asserting on the
*remote's* board state. `sleep` is also stubbed in the loop tests, and `MAX_ITERATIONS`
bounds otherwise-infinite runs. When adding behavior, add a `test_*` function and register
it in the runner block at the bottom of the file.

## Conventions

- `set -euo pipefail` everywhere; all config is env vars with `${VAR:-default}` defaults.
  `TARGET_REPO` is the only required one.
- Every script and non-trivial function carries a comment explaining the *why*, not just
  the what — match that density. The README documents the full config matrix and rationale.
- Keep the harness repo-agnostic and minimal: configuration is "git remote + branch + creds",
  everything else has a sane default.
