# One-shot iteration runner

**Type:** AFK

## What to build

The tracer bullet for the loop: a single, non-repeating run that drives one
`/implement` invocation against a configured target repo end-to-end.

Given a target git remote and branch (from config), the runner ensures a local
checkout of that branch exists and is up to date, then invokes headless Claude
once with `claude -p "/implement" --dangerously-skip-permissions`. The target
repo carries its own `/implement` skill, `slice-lander` agent, `CLAUDE.md`, and
`kanban-board/` columns — the runner does not provide them. The `/implement`
process commits and pushes (and parks blockers) per its own rules; the runner
just runs it once and exits with the run's result.

This slice proves the riskiest integration in the whole system: git push
authentication, Claude subscription authentication, and the `/implement` process
actually executing unattended with permissions bypassed.

## Acceptance criteria

- [ ] Target repo + branch are read from configuration (branch defaults to `main`).
- [ ] A local checkout of the configured branch is created if absent and updated if present.
- [ ] Runs `claude -p "/implement"` with `--dangerously-skip-permissions` against the checkout.
- [ ] Against a fixture repo containing one refined story, a single run lands the story (commits + pushes each slice) or parks it to `04-user-verification/`, exactly as `/implement` dictates.
- [ ] The runner does not inject or modify the target repo's skills/agents/kanban structure.
- [ ] The runner exits after one invocation (no looping yet) and surfaces the run's success/failure.

## Blocked by

- None — can start immediately.
