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

It ensures a local checkout of the configured branch — cloning if absent, or on
an existing checkout discarding any crash leftovers (`git reset --hard` +
`git clean -fd`) before fast-forwarding, so an incomplete slice can't wedge the
loop or block the pull. This is safe because the loop owns the isolated checkout
and slice work is atomic-per-commit; the cleanup only touches the working tree
and never rewrites committed history. It then runs
`claude -p "/implement" --dangerously-skip-permissions` inside it. The target
repo carries its own `/implement` skill, `slice-lander` agent, `CLAUDE.md`, and
`kanban-board/` columns — the runner provides none of them and modifies nothing;
`/implement` commits, pushes, and parks per its own rules.

The `claude -p` run is wrapped in a `timeout` (`RUN_TIMEOUT`, default 30m) so a
hung session can't stall the loop forever. A run that exceeds the limit is sent
SIGTERM — and SIGKILLed after `RUN_KILL_AFTER` if it ignores that — and exits
non-zero (124), so callers (and the loop) see it as a failed attempt.

### Configuration (environment)

| Variable         | Required | Default                | Meaning                                   |
| ---------------- | -------- | ---------------------- | ----------------------------------------- |
| `TARGET_REPO`    | yes      | —                      | git remote URL of the target repo         |
| `TARGET_BRANCH`  | no       | `main`                 | branch to work on                         |
| `CHECKOUT_DIR`   | no       | `$HOME/.coder/checkout`| where the local checkout lives            |
| `CLAUDE_BIN`     | no       | `claude`               | Claude CLI binary (override in tests)     |
| `RUN_TIMEOUT`    | no       | `30m`                  | max wall-clock for one `/implement` run   |
| `RUN_KILL_AFTER` | no       | `30s`                  | grace before SIGKILL if it ignores SIGTERM|

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

#### Retry cap → quarantine

A story whose `/implement` keeps crashing (rather than cleanly parking or
completing) would otherwise be resumed forever, burning usage. After resuming a
story the loop checks the board: if the story is **still** in
`03-in-progress/`, the run crashed or timed out without finishing — a failed
attempt. Consecutive failed attempts per story slug are tallied in a
volume-persisted state file (`STATE_FILE`), so the count survives a process
restart. A clean park to `04-user-verification/` or a successful completion (the
story leaves `03-in-progress/`) clears the count.

Once a story reaches `MAX_RETRIES` consecutive failures, the loop **quarantines**
it: it parks the folder to `kanban-board/04-user-verification/` with a
`QUARANTINE.md` "crashed N×" note, commits and pushes that, and resets the count.
This reuses the existing human-needed column instead of inventing a new board
state, and clears `03-in-progress/` so the loop keeps draining `02-refined/`.

### Configuration (environment)

In addition to the run-once variables above:

| Variable              | Default                          | Meaning                                            |
| --------------------- | -------------------------------- | -------------------------------------------------- |
| `WORK_SLEEP`          | `5`                              | seconds to sleep after a work iteration            |
| `IDLE_SLEEP`          | `60`                             | seconds to sleep after an idle iteration           |
| `KANBAN_REFINED`      | `kanban-board/02-refined`        | refined column path within the repo                |
| `KANBAN_IN_PROGRESS`  | `kanban-board/03-in-progress`    | in-progress column path within the repo            |
| `KANBAN_VERIFICATION` | `kanban-board/04-user-verification` | user-verification (quarantine) column path      |
| `MAX_RETRIES`         | `3`                              | consecutive failed resumes before quarantine       |
| `STATE_FILE`          | `$HOME/.coder/state/retry-counts`| volume-persisted per-slug failure counts           |
| `MAX_ITERATIONS`      | _(empty)_                        | stop after N iterations; empty = forever           |

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

## Deployment — Docker

The loop ships as a Docker image: one container per target repo. The image
([`Dockerfile`](Dockerfile)) bundles `git` + the Claude Code CLI on a Node 22
base and runs the loop as its entrypoint. Scaling to more repos means running
more containers, each fully isolated.

The image runs as a **non-root** user on purpose — `claude
--dangerously-skip-permissions` refuses to run as root, and the container plus
its volumes (no prod credentials, a repo-scoped git PAT, a disposable checkout)
are the real safety boundary.

### Volumes

Two paths are backed by volumes so they survive container restarts:

| Mount point      | Env var (default)             | Why it persists                                              |
| ---------------- | ----------------------------- | ----------------------------------------------------------- |
| `/data/checkout` | `CHECKOUT_DIR` (`=/data/checkout`) | a restart reuses the checkout instead of a full re-clone (the per-iteration hard-reset + pull keeps it clean) |
| `/data/state`    | `STATE_FILE` (`=/data/state/retry-counts`) | a quarantined poison-pill's consecutive-failure count survives restarts |

[`docker-compose.yml`](docker-compose.yml) declares both as named volumes and
sets `restart: unless-stopped`, so the loop comes back after a crash or host
reboot (a manual `stop` stays stopped). For a bare `docker run`, pass
`--restart unless-stopped -v coder-checkout:/data/checkout -v
coder-state:/data/state`.

### Credentials

Wired entirely through the environment by
[`bin/docker-entrypoint.sh`](bin/docker-entrypoint.sh), which configures git and
then execs the loop:

- **Claude (subscription login).** On a trusted machine run `claude setup-token`
  once — it walks through an interactive OAuth login and prints a long-lived
  (~1-year) token tied to your Max/Pro plan's *included* usage (not a metered
  `ANTHROPIC_API_KEY` bill). Supply it to the container as
  `CLAUDE_CODE_OAUTH_TOKEN`; the `claude` CLI consumes it directly.
  - Caveats (per [design.md](design.md)): the token eventually expires and needs
    re-running `setup-token`, and a busy loop draws from the same plan allowance
    as your interactive Claude usage.
- **Git push/pull (scoped HTTPS PAT).** Create a Personal Access Token scoped to
  just the target repo and pass it as `GIT_PAT` (with optional `GIT_USERNAME`,
  default `x-access-token`). The entrypoint writes it into git's credential
  store keyed to `TARGET_REPO`'s host, so every git call authenticates without
  the token ever landing in a remote URL or in `argv`. Rotate/revoke per repo.
- **Committer identity.** `GIT_USER_NAME` / `GIT_USER_EMAIL` (sane defaults) are
  set globally so the commits `/implement` makes in the target repo succeed in
  an otherwise-fresh container.

### Run

```sh
# 1. Authenticate once on a trusted machine and capture the token.
claude setup-token            # prints CLAUDE_CODE_OAUTH_TOKEN

# 2. Provide config + secrets. Copy the template and fill in the three required
#    keys (TARGET_REPO, CLAUDE_CODE_OAUTH_TOKEN, GIT_PAT); the rest have defaults.
cp .env.example .env
$EDITOR .env

# 3. Bring up the stack. docker compose loads .env automatically.
docker compose up -d --build
docker compose logs -f
```

`docker-compose.yml` loads `.env` via `env_file` with `required: false`, so the
file is optional — if you'd rather inject the variables from the shell or an
orchestrator, the stack still comes up without it. `.env` is git-ignored;
`.env.example` is the committed template.

To verify persistence: let the loop drain the target repo's `02-refined/`
column, then `docker compose restart`. The logs show `updating existing
checkout` (not `cloning`), and `/data/state/retry-counts` still carries any
recorded failure counts.

### State file format

`STATE_FILE` is a flat, tab-separated table — one line per tracked story,
`<slug>\t<consecutive-failure-count>`:

```
04-flaky-story	2
07-wedged-story	1
```

A clean park or completion drops the slug's line; quarantine resets it. The
format is deliberately structured and externally readable so the deferred v2
HTTP observability endpoint (see [design.md](design.md)) can expose retry counts
without re-architecting how the loop persists them.
