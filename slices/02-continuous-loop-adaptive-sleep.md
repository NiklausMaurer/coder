# Continuous loop with board-driven adaptive sleep

**Type:** AFK

## What to build

Wrap the one-shot runner in a continuous loop that drains the refined column and
backs off when idle.

Each iteration pulls the configured branch, then inspects
`kanban-board/02-refined/` to decide whether there is work: if a refined story
exists, run one `/implement` invocation (no-slug form, which drains the lowest
`NN-` story); if the column is empty, the iteration is idle. Sleep is adaptive —
a short delay after doing work (so a full column drains quickly) and a longer
back-off when idle (to poll for freshly pushed human work). Exactly one story is
attempted per pull, so each run works against the freshest remote state.

The board inspection is the work/idle signal — the loop does not parse Claude's
stdout to decide timing.

## Acceptance criteria

- [ ] Loop runs indefinitely: pull → inspect board → (work or idle) → sleep → repeat.
- [ ] When `02-refined/` contains stories, one `/implement` (no-slug) runs per iteration.
- [ ] When `02-refined/` is empty, the iteration does no work and backs off with the longer idle interval.
- [ ] Sleep is short after a work iteration and long after an idle iteration.
- [ ] A fixture repo with a 3-story refined column drains one story per iteration and then settles into idle polling.
- [ ] At most one story is attempted per pull.

## Blocked by

- 01 — One-shot iteration runner
