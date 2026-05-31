# Per-run timeout

**Type:** AFK

## What to build

Bound how long a single `/implement` invocation may run so a hung session can't
stall the loop forever.

Wrap the `claude -p` call in a timeout. A run that exceeds the limit is killed,
and the loop treats that as a failed attempt for the story being worked (the
signal the quarantine logic later consumes). The timeout value has a sane default
and is overridable via config.

## Acceptance criteria

- [ ] The `claude -p` invocation is wrapped in a timeout with a sane configurable default.
- [ ] A run exceeding the timeout is terminated rather than left running.
- [ ] A timed-out run is reported as a failed attempt (not a success), and the loop continues to the next iteration.
- [ ] Verifiable: a stub that hangs past the limit is killed at the limit and the iteration ends.

## Blocked by

- 01 — One-shot iteration runner
