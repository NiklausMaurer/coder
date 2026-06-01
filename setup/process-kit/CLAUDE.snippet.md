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
`03-in-progress` / `04-user-verification`; getting stories *into* `02-refined` (refinement,
slicing) is this repo's own concern, not the loop's.

The loop treats the checkout as disposable (`git reset --hard` + `git clean -fd` each
iteration), which is safe only because **slice work is atomic per commit** — uncommitted state
is always an incomplete slice that re-runs.
