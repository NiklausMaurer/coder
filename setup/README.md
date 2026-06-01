# setup — onboarding new target repos

The loop in `bin/` is repo-agnostic: it just runs `/implement` inside a checkout
of a target repo. For that to do anything, the target repo must carry the process
artifacts the loop depends on. This directory holds the tooling to set those up.

Two independent steps:

1. **Onboard the target repo** — `init-target.sh` scaffolds the `/implement` skill,
   the `slice-lander` agent, and the `kanban-board/` columns into the target repo,
   then (by default) asks Claude to fill in that repo's build/test/architecture
   specifics. Run once per repo; commit the result to the target's history.
2. **Configure the loop** — `setup-env.sh` is an interactive wizard that writes
   coder's `.env` (which repo to drain, with which credentials).

## Why scaffold, not inject at runtime

The loop deliberately does **not** drop these files into the disposable checkout
each run. Onboarding scaffolds them into the target repo **once**, committed to its
history, because:

- It keeps the loop's repo-agnostic invariant intact (the loop owns no process).
- The `slice-lander` is inherently repo-specific — it knows how to *build and test
  this repo*. A single hosted copy can't run the right commands across repos, so it
  ships as a template with blanks the onboarding step fills from the actual repo.
- A committed scaffold is reviewable and diffable; runtime injection is invisible
  and would collide with a repo (like `nikos`) that already has its own.

## `process-kit/` — the templates

```
process-kit/
  .claude/skills/implement/SKILL.md    # process-generic, copied ~verbatim
  .claude/skills/{add-story,refine,to-slices,grill-me}/SKILL.md  # queue-filling pipeline
  .claude/skills/accept-verification/SKILL.md  # human-side resume of a parked story
  .claude/agents/slice-lander.md       # template; repo-specific blanks marked coder:autofill
  kanban-board/{01-backlog,02-refined,03-in-progress,04-user-verification}/.gitkeep
  kanban-board/README.md               # the process guide — how the story lifecycle works
  CLAUDE.snippet.md                    # section appended to the target's root CLAUDE.md
```

New to the process? **[`process-kit/kanban-board/README.md`](process-kit/kanban-board/README.md)**
is the full newcomer's guide — stories, slices, AFK/HITL, the columns, and which skill
moves work where. It's scaffolded into every onboarded repo so its users have it too.

Two tiers of skill:

- **Loop preconditions** — `implement` + `slice-lander`. These are what the running
  loop needs. `implement` is portable (kanban/slice mechanics only). `slice-lander`
  carries `<!-- coder:autofill <key> -->` blocks for the parts that differ per repo —
  **architecture** invariants, the **verify** command gate, and the **commit-convention**
  (message style + trailer).
- **Human-driven lifecycle** — `add-story` → `refine` (which orchestrates `to-slices`
  + `grill-me`) fills the queue; `accept-verification` is the accept path for a story
  `/implement` parked in `04-user-verification/` for a UI check. This half runs on your
  machine, never in the loop's container. Bundled so a fresh repo has the whole process,
  not just the loop's half. `refine` and `accept-verification` carry a **commit-convention**
  autofill block.

`init-target.sh --no-autofill` leaves the autofill blocks as `TODO(coder)` / `{{…}}`
markers for a human; the default fills them with Claude.

## `init-target.sh` — onboard a target repo

```sh
# Run against a local working copy of the target repo.
setup/init-target.sh /path/to/target-repo

# Skip the Claude pass and fill the slice-lander blanks yourself.
setup/init-target.sh /path/to/target-repo --no-autofill

# Re-run to overwrite already-installed kit files (e.g. after a kit update).
setup/init-target.sh /path/to/target-repo --force
```

It never clobbers existing kit files without `--force`, only *adds* missing board
columns, and appends the CLAUDE.md section at most once. After it runs: review the
diff (especially the slice-lander blanks), then commit and push to the target repo.

## `setup-env.sh` — build coder's `.env`

```sh
setup/setup-env.sh
```

Walks through the three required keys (`TARGET_REPO`, `CLAUDE_CODE_OAUTH_TOKEN`,
`GIT_PAT`) and the common optional ones, offering to run `claude setup-token` for
you. Secrets are read without echo; the file is written owner-only and an existing
`.env` is backed up to `.env.bak`. See `.env.example` for the full config matrix.

Then: `docker compose up -d --build`.

## Credits & licensing

Two skills in `process-kit/` come from Matt Pocock's
[Skills For Real Engineers](https://github.com/mattpocock/skills) (MIT-licensed),
re-used here under MIT:

- **`grill-me`** — a verbatim copy of upstream `skills/productivity/grill-me`.
- **`to-slices`** — adapted from upstream `skills/engineering/to-issues`, re-pointed to
  write kanban slice files instead of publishing issues to a tracker.

Each derived file carries this attribution inline (so it travels into every repo it's
scaffolded into), and the top-level [`LICENSE`](../LICENSE) records the third-party notice
alongside coder's own MIT license. The rest of the kit (`implement`, `slice-lander`,
`add-story`, `refine`, `accept-verification`) and the loop are coder's own.
