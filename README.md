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

## Tests

```sh
bash test/run-once.test.sh
```

A self-contained bash harness (no `bats`) that builds fixture git repos, stubs
the Claude CLI, and exercises the runner end-to-end.
