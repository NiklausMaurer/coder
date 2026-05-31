# coder — autonomous implementation loop

An autonomous loop that continuously drains `kanban-board/02-refined` stories of
a target repository via the [nikos](../nikos) `/implement` process, parking
anything that needs a human, then polls for more. See [problem.md](problem.md)
and [design.md](design.md) for the full statement and design.

The loop is built up slice by slice (see [`slices/`](slices)). This is the
current state:

## `bin/run-once.sh` — one-shot iteration runner

The tracer bullet: a single, non-repeating run that drives one `/implement`
invocation against a configured target repo end-to-end, then exits.

It ensures a local checkout of the configured branch (cloning if absent,
fast-forwarding if present) and runs
`claude -p "/implement" --dangerously-skip-permissions` inside it. The target
repo carries its own `/implement` skill, `slice-lander` agent, `CLAUDE.md`, and
`kanban-board/` columns — the runner provides none of them and modifies nothing;
`/implement` commits, pushes, and parks per its own rules.

### Configuration (environment)

| Variable        | Required | Default                | Meaning                              |
| --------------- | -------- | ---------------------- | ------------------------------------ |
| `TARGET_REPO`   | yes      | —                      | git remote URL of the target repo    |
| `TARGET_BRANCH` | no       | `main`                 | branch to work on                    |
| `CHECKOUT_DIR`  | no       | `$HOME/.coder/checkout`| where the local checkout lives       |
| `CLAUDE_BIN`    | no       | `claude`               | Claude CLI binary (override in tests)|

### Run

```sh
TARGET_REPO=https://github.com/you/your-repo.git bin/run-once.sh
```

The runner exits with the `/implement` run's status, so callers can tell whether
the run succeeded.

## `bin/loop.sh` — continuous loop with adaptive sleep

Wraps the one-shot runner in a loop that drains the refined column and backs off
when idle. Each iteration pulls the configured branch, then inspects the board
**resume-then-drain** to decide what to work on:

- a story stranded in `kanban-board/03-in-progress/` → resume it via
  `/implement <slug>` (self-healing against a previous run killed or crashed
  mid-story; the no-slug form would never pick it back up),
- else a story in `kanban-board/02-refined/` → no-slug `/implement` (drains the
  lowest `NN-` story),
- else the iteration is idle.

When several stories sit in a column, the lowest `NN-` prefix is chosen. It then
sleeps adaptively — short after doing work (drain a full column fast), long when
idle (poll for freshly pushed work). The board, not Claude's stdout, is the
work/idle signal, and exactly one story is attempted per pull.

### Configuration (environment)

In addition to the run-once variables above:

| Variable             | Default                     | Meaning                                  |
| -------------------- | --------------------------- | ---------------------------------------- |
| `WORK_SLEEP`         | `5`                         | seconds to sleep after a work iteration  |
| `IDLE_SLEEP`         | `60`                        | seconds to sleep after an idle iteration |
| `KANBAN_REFINED`     | `kanban-board/02-refined`   | refined column path within the repo      |
| `KANBAN_IN_PROGRESS` | `kanban-board/03-in-progress`| in-progress column path within the repo |
| `MAX_ITERATIONS`     | _(empty)_                   | stop after N iterations; empty = forever |

### Run

```sh
TARGET_REPO=https://github.com/you/your-repo.git bin/loop.sh
```

## Tests

```sh
bash test/run-once.test.sh
bash test/loop.test.sh
```

Self-contained bash harnesses (no `bats`) that build fixture git repos and stub
the Claude CLI (and `sleep`) to exercise the runner and loop end-to-end.
