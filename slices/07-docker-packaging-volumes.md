# Docker packaging + persistent volumes

**Type:** AFK

## What to build

Package the loop as a Docker container deploying one instance per target repo.

The image bundles `claude` and `git` and runs the loop as its entrypoint.
Configuration (repo remote, branch, intervals, retry cap, timeout) is supplied
via environment. Two volumes persist across container restarts: the repo
checkout (so restarts don't force a full re-clone — the per-iteration hard-reset
+ pull keeps it clean) and the state file (so a quarantined poison-pill's failure
count survives restarts). A restart policy keeps the loop running across crashes
and reboots. Document the credential wiring: Claude subscription login
(`claude setup-token`) and a scoped HTTPS git PAT for the target repo.

The state file is kept in a structured, externally-readable form so the deferred
v2 HTTP observability endpoint can expose it later without re-architecting.

## Acceptance criteria

- [ ] A Docker image builds with `claude` + `git` and runs the loop as its entrypoint.
- [ ] Repo, branch, and tuning values are configurable via environment variables.
- [ ] A volume persists the repo checkout; a volume persists the state file.
- [ ] A restart policy is configured so the container restarts on crash/reboot.
- [ ] Credential wiring (subscription login + scoped git PAT) is documented for deployment.
- [ ] Verifiable: `docker run` with config drains a fixture repo's refined column; restarting the container preserves the checkout (no re-clone) and the retry-count state.
- [ ] The state file format is documented and readable for a future HTTP observability layer.

## Blocked by

- 02 — Continuous loop with board-driven adaptive sleep (ideally land after 01–06)
