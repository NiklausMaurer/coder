# Resume-then-drain crash recovery

**Type:** AFK

## What to build

Make the loop self-healing against a previous run that was killed or crashed
mid-story, leaving a story folder stranded in `kanban-board/03-in-progress/`.
The no-slug `/implement` only picks from `02-refined/`, so without this a
stranded story would never be picked back up.

Change the board inspection so each iteration resumes before draining: if a story
exists in `03-in-progress/`, run `claude -p "/implement <slug>"` to resume it;
otherwise fall back to draining the lowest story in `02-refined/`; otherwise
idle. If more than one story sits in `03-in-progress/`, resume the lowest `NN-`
prefix.

## Acceptance criteria

- [ ] Each iteration prefers a story in `03-in-progress/` (resumed via `/implement <slug>`) over draining `02-refined/`.
- [ ] When `03-in-progress/` is empty, behavior falls back to no-slug draining of `02-refined/` (slice 02 behavior).
- [ ] When both columns are empty, the iteration is idle.
- [ ] If multiple stories are in `03-in-progress/`, the lowest `NN-` prefix is chosen.
- [ ] Verifiable: kill a run mid-story so its folder stays in `03-in-progress/`; the next iteration resumes that same story rather than skipping it.

## Blocked by

- 02 — Continuous loop with board-driven adaptive sleep
