# Dirty-tree hygiene

**Type:** AFK

## What to build

Ensure each iteration starts from a clean working tree so a crash that left
uncommitted changes can't wedge the loop or pollute a resume.

Before pulling, the loop discards any uncommitted leftovers with
`git reset --hard` and `git clean -fd`, then pulls. This is safe because the loop
owns the isolated checkout and `slice-lander` work is atomic-per-commit — anything
uncommitted is an incomplete slice that will re-run from its `02-in-progress/`
marker.

## Acceptance criteria

- [ ] Every iteration runs `git reset --hard` + `git clean -fd` before `git pull`.
- [ ] Verifiable: with uncommitted changes and untracked files present in the checkout, the iteration discards them and the subsequent pull succeeds (no "would be overwritten" / dirty-tree failure).
- [ ] Committed history on the configured branch is never rewritten by the cleanup (no rebase/amend/force).
- [ ] Cleanup is scoped to the loop's own checkout.

## Blocked by

- 01 — One-shot iteration runner
