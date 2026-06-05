# coder — autonomous implementation loop

An autonomous loop that continuously drains `kanban-board/02-refined` stories of
a target repository via the [nikos](../nikos) `/implement` process, parking
anything that needs a human, then polls for more. See [problem.md](problem.md)
and [design.md](design.md) for the full statement and design.

## Quick start

Run one container per target repo with Docker Compose:

```sh
# 1. One-time: generate a Claude subscription token on a trusted machine.
claude setup-token            # prints CLAUDE_CODE_OAUTH_TOKEN

# 2. Configure. Fill in the three required keys; everything else has defaults.
cp .env.example .env
$EDITOR .env                  # TARGET_REPO, CLAUDE_CODE_OAUTH_TOKEN, GIT_PAT
# …or run the wizard instead of editing by hand: setup/setup-env.sh

# 3. Build and run in the background.
docker compose up -d --build
docker compose logs -f        # watch the loop drain the board
```

That's it — the loop clones the target repo into a persistent volume and starts
draining its `kanban-board/02-refined` column. To stop it: `docker compose down`
(the checkout and retry-count volumes persist; add `-v` to wipe them).

## How the process works

The loop drains a **kanban board of stories**. A *story* is a folder under
`kanban-board/`; refining it breaks it into thin, end-to-end **tracer-bullet
slices** that an agent can land one at a time. Work flows left-to-right through
the columns, mostly unattended:

```
/add-story ─▶ 01-backlog ─/refine─▶ 02-refined ─/implement─▶ 03-in-progress ─▶ done (deleted)
                                                     │                ▲
                                         parks blocker│                │ /accept-verification
                                                     ▼                │
                                            04-user-verification ──────┘
```

You fill the queue interactively (`/add-story`, then `/refine` — which grills the
problem and slices it). The loop drains it autonomously: `/implement` claims the
next refined story and lands its slices via a `slice-lander` subagent, pushing each
one and **parking** anything that needs a human in `04-user-verification/`, where you
release it with `/accept-verification`. The loop only ever runs `/implement`; the
rest is human-driven and runs on your machine.

The full newcomer's guide — stories vs slices, AFK/HITL, every column and skill — is
**[`setup/process-kit/kanban-board/README.md`](setup/process-kit/kanban-board/README.md)**,
which onboarding installs into each target repo's `kanban-board/`.

## Onboarding a new target repo

The loop is repo-agnostic and owns no process — so a target repo must already
carry the artifacts `/implement` needs: the `implement` skill, the `slice-lander`
agent, and the `kanban-board/` columns. To set those up in a repo that doesn't
have them yet:

```sh
setup/init-target.sh /path/to/target-repo   # scaffold + Claude-fill repo specifics
```

It copies the process kit from `setup/process-kit/`, fills in that repo's
build/test/architecture specifics, and leaves you a diff to review and commit.
See [`setup/README.md`](setup/README.md) for the full onboarding story (and why
the loop scaffolds these once rather than injecting them at runtime).

Watching the logs you'll see two channels. Operational plumbing (checkout, sleep,
retries) is logged with a `[loop]`/`[run-once]` prefix on **stderr**; the work
narration you usually care about is on **stdout** with a `[coder]` prefix:

```text
[coder] working on story: 03-export-csv (draining refined column)
[coder] landed slice: a1b2c3d add csv column mapping
[coder] landed slice: e4f5a6b stream rows to the response
```

Each story is named before its run (on both the resume and the no-slug drain
path), and each landed slice is read straight from the commits the run pushed —
git, not Claude's stdout, so the line is true whether the run lands one slice or
several. A run that crashes or parks without committing reports `no slices landed
this run`. To follow just this channel: `docker compose logs -f | grep '\[coder\]'`.

For a peek *inside* a run, the runner asks Claude for `--output-format stream-json`
and narrates the top-level subagent invocations it makes (the `/implement` skill
delegates landing to the `slice-lander` agent), plus the final result, on stdout
with an `[implement]` prefix:

```text
[implement] subagent slice-lander: Land the export-csv slice
[implement] result (success): landed 2 slices, parked the rest
```

This needs `jq` (bundled in the image); the nested events the subagent itself
emits are filtered out, so you see only the parent run's delegations.

See [Deployment — Docker](#deployment--docker) for credentials, volumes, restart
behavior, and the rest of the configuration.

---

The loop is built up slice by slice. This is the current state:

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

After the checkout, the runner installs whatever Claude plugins the target repo
declares in `.claude/coder-plugins` (one `<plugin>@<marketplace>  <git-url>` per
line) — a `claude plugin marketplace add` + `claude plugin install` per entry,
into `~/.claude`. This is the one piece of target-specific tooling the harness
can't pick up just by being inside the checkout (skills and agents live in the
tree and load automatically; plugins install into `~/.claude`). Keeping it in the
target's manifest is what lets one repo-agnostic image drive any target — a
frontend repo's `frontend-design` dependency lives in that repo, not in this
image. The manifest is fingerprinted, so an unchanged one isn't re-installed each
iteration; a repo that needs no plugins simply omits the file.

If the target repo ships a `flake.nix`, the run is entered through
`nix develop --command`, so the story's verify gate (e.g.
`pnpm typecheck/lint/test/build`) sees the *target's* declared toolchain — the
right language runtime, package manager, and system deps — rather than just the
image's base tooling. The image carries Nix; the target carries its toolchain in
the flake, which is what lets one image drive targets with wildly different build
requirements. The flake's `shellHook` runs first, so it's also where a target
repopulates dependencies the per-iteration `git clean -fd` wiped (e.g.
`pnpm install`). A repo with no `flake.nix` runs on the base tooling (the simple
case); if a flake is present but `nix` is unavailable, the loop warns and falls
back to a direct run. See `setup/process-kit/flake.example.nix` for a starting
point.

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
| `PLUGIN_MANIFEST`| no       | `.claude/coder-plugins`| where the target declares its Claude plugins (within the checkout) |
| `PLUGIN_SYNC_MARKER`| no    | `$HOME/.coder/plugin-sync`| fingerprint of the last-installed manifest, to skip re-syncing |
| `NIX_BIN`        | no       | `nix`                  | Nix binary used to enter a target's `flake.nix` dev shell |

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
([`Dockerfile`](Dockerfile)) bundles `git`, the Claude Code CLI, and **Nix** on a
Node 22 base and runs the loop as its entrypoint. The Node 22 base is only for the
Claude CLI itself; a target's own build/test toolchain comes from its `flake.nix`
dev shell (see *Toolchain* above), so the image stays repo-agnostic. Scaling to
more repos means running more containers, each fully isolated.

The image runs as a **non-root** user on purpose — `claude
--dangerously-skip-permissions` refuses to run as root, and the container plus
its volumes (no prod credentials, a repo-scoped git PAT, a disposable checkout)
are the real safety boundary.

### Volumes

Three paths are backed by volumes so they survive container restarts:

| Mount point      | Env var (default)             | Why it persists                                              |
| ---------------- | ----------------------------- | ----------------------------------------------------------- |
| `/data/checkout` | `CHECKOUT_DIR` (`=/data/checkout`) | a restart reuses the checkout instead of a full re-clone (the per-iteration hard-reset + pull keeps it clean) |
| `/data/state`    | `STATE_FILE` (`=/data/state/retry-counts`) | a quarantined poison-pill's consecutive-failure count survives restarts |
| `/nix`           | — (the Nix store)             | a target's dev-shell toolchain is built/downloaded once, not on every container recreate |

[`docker-compose.yml`](docker-compose.yml) declares all three as named volumes and
sets `restart: unless-stopped`, so the loop comes back after a crash or host
reboot (a manual `stop` stays stopped). For a bare `docker run`, pass
`--restart unless-stopped -v coder-checkout:/data/checkout -v
coder-state:/data/state -v coder-nix:/nix`.

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

### Configuration file

The [Quick start](#quick-start) covers the commands. Configuration comes from a
`.env` file (copy [`.env.example`](.env.example)): `docker-compose.yml` loads it
via `env_file` with `required: false`, so it's optional — if you'd rather inject
the variables from the shell or an orchestrator, the stack still comes up without
it. `.env` is git-ignored; `.env.example` is the committed template.

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

## License

MIT — see [`LICENSE`](LICENSE).

The onboarding kit bundles two skills from Matt Pocock's
[Skills For Real Engineers](https://github.com/mattpocock/skills) (MIT): `grill-me`
(verbatim) and `to-slices` (adapted from his `to-issues`). Each carries its
attribution inline and the third-party notice is recorded in `LICENSE`. See
[`setup/README.md`](setup/README.md#credits--licensing) for details.
