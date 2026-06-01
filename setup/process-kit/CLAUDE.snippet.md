<!-- coder:process-kit — paste this section into the target repo's root CLAUDE.md. -->

## Autonomous implementation loop (coder)

This repo is drained by the [coder](https://github.com/NiklausMaurer/coder) autonomous loop,
which repeatedly runs `/implement` to land refined stories. Two preconditions, scaffolded by
`coder/setup/init-target.sh`, make that work:

- **`.claude/skills/implement`** — orchestrates a story end-to-end: claims it from
  `kanban-board/02-refined/`, runs `slice-lander` subagents one slice at a time, pushes each
  landed slice, parks anything needing a human in `kanban-board/04-user-verification/`.
- **`.claude/agents/slice-lander`** — lands exactly one slice: implements it, runs this repo's
  verification gate, commits, moves the slice file `01-todo/ → 02-in-progress/ → 03-done/`.

The board lives at `kanban-board/` with columns `01-backlog`, `02-refined`, `03-in-progress`,
`04-user-verification`. The loop only ever reads `02-refined` (work to drain) and writes
`03-in-progress` / `04-user-verification`.

Getting stories *into* `02-refined` is human-driven and runs on your own machine, **not** in
the loop. The kit also bundles that queue-filling pipeline so a fresh repo has it:
`/add-story` (capture a problem in `01-backlog`), then `/refine` (grill it, slice it via
`/to-slices` + `/grill-me`, promote to `02-refined`). The loop never invokes these — it only
runs `/implement`.

The loop commits **directly to the working branch** (it `git reset --hard origin/<branch>`
each iteration), which is safe only because **slice work is atomic per commit** — uncommitted
state is always an incomplete slice that re-runs. Adopting the loop therefore means landing
work as commits on the branch, not via feature branches or PRs.
