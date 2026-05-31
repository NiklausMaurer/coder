# Retry cap → quarantine

**Type:** AFK

## What to build

Stop a story that repeatedly crashes `/implement` (as opposed to cleanly parking)
from being resumed forever and burning usage.

Persist a count of consecutive failed attempts per story slug in a state file. A
failed attempt is a crashing or timed-out run that leaves the story in
`03-in-progress/` (a clean park to `04-user-verification/` or a successful
completion resets/clears the count). After N consecutive failures on the same
in-progress story (N has a sane configurable default, ≈3), the loop quarantines
it: park the story folder to `kanban-board/04-user-verification/` with a note
that it crashed N times, then reset its count. Quarantining reuses the existing
human-needed column and clears `03-in-progress/` so the loop can keep draining.

## Acceptance criteria

- [ ] Consecutive failed-attempt counts are tracked per story slug in a state file.
- [ ] A clean park or a successful completion resets that story's count.
- [ ] After N consecutive failures (configurable, default ≈3) the story is parked to `04-user-verification/` with a "crashed N×" note and its count reset.
- [ ] After quarantine, `03-in-progress/` no longer holds that story and the loop proceeds to drain `02-refined/`.
- [ ] Verifiable: a poison-pill story that always crashes is parked after N failed resumes; the failure counter survives a process restart (does not reset to zero on restart).

## Blocked by

- 03 — Resume-then-drain crash recovery (benefits from 05 — Per-run timeout)
