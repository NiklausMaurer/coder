#!/usr/bin/env bash
#
# One-shot iteration runner — the tracer bullet for the autonomous loop.
#
# Drives a single `/implement` invocation against a configured target repo,
# end-to-end, then exits. No looping (that is slice 02). The target repo carries
# its own `/implement` skill, `slice-lander` agent, CLAUDE.md, and kanban-board/
# columns; this runner does not provide, inject, or modify any of them — it only
# ensures a checkout and runs Claude once.
#
# Configuration (environment variables):
#   TARGET_REPO    (required) git remote URL of the target repository
#   TARGET_BRANCH  branch to work on                       (default: main)
#   CHECKOUT_DIR   where the local checkout lives          (default: $HOME/.coder/checkout)
#   CLAUDE_BIN     Claude CLI binary (overridable for tests) (default: claude)
#   RUN_TIMEOUT    max wall-clock for one /implement run    (default: 30m)
#   RUN_KILL_AFTER grace before SIGKILL if it ignores SIGTERM (default: 30s)
#
# Exit status is the `/implement` run's status, so a caller (or the future loop)
# can tell whether the run succeeded. A run that exceeds RUN_TIMEOUT is killed and
# exits non-zero (124), so the caller sees it as a failed attempt.

set -euo pipefail

log() { printf '[run-once] %s\n' "$*" >&2; }

# --- Configuration -----------------------------------------------------------

TARGET_REPO="${TARGET_REPO:-}"
TARGET_BRANCH="${TARGET_BRANCH:-main}"
CHECKOUT_DIR="${CHECKOUT_DIR:-$HOME/.coder/checkout}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
RUN_TIMEOUT="${RUN_TIMEOUT:-30m}"
RUN_KILL_AFTER="${RUN_KILL_AFTER:-30s}"

# --- Steps -------------------------------------------------------------------

# Ensure a local checkout of TARGET_BRANCH exists and is up to date. Clones when
# absent; on an existing checkout, discards any crash leftovers (dirty-tree
# hygiene) and then fast-forwards.
#
# Before pulling, `git reset --hard` + `git clean -fd` throw away any uncommitted
# changes and untracked files so an incomplete slice left by a crashed run can't
# wedge the loop or block the fast-forward ("would be overwritten" / dirty-tree
# failure). This is safe because the loop owns this isolated checkout and slice
# work is atomic-per-commit — anything uncommitted is an incomplete slice that
# re-runs from its `02-in-progress/` marker. The cleanup is scoped to this
# checkout and only touches the working tree; committed history on the branch is
# never rewritten (no rebase/amend/force).
ensure_checkout() {
  if [ -d "$CHECKOUT_DIR/.git" ]; then
    log "updating existing checkout at $CHECKOUT_DIR"
    git -C "$CHECKOUT_DIR" fetch --quiet origin "$TARGET_BRANCH"
    git -C "$CHECKOUT_DIR" checkout --quiet "$TARGET_BRANCH"
    git -C "$CHECKOUT_DIR" reset --hard --quiet
    git -C "$CHECKOUT_DIR" clean -fd --quiet
    git -C "$CHECKOUT_DIR" pull --ff-only --quiet origin "$TARGET_BRANCH"
  else
    log "cloning $TARGET_REPO (branch $TARGET_BRANCH) into $CHECKOUT_DIR"
    mkdir -p "$(dirname "$CHECKOUT_DIR")"
    git clone --quiet --branch "$TARGET_BRANCH" "$TARGET_REPO" "$CHECKOUT_DIR"
  fi
}

# Run `/implement` once, headless, with permissions bypassed (nobody is present
# to approve prompts; the container/VM is the safety boundary). Runs inside the
# checkout so Claude picks up the target repo's own skills and kanban board.
#
# With no argument, runs the no-slug form (drains the lowest `02-refined/`
# story). With a slug argument, runs `/implement <slug>` to resume that specific
# story (used by the loop to recover a story stranded in `03-in-progress/`).
#
# The run is bounded by `timeout` so a hung session can't stall the loop forever:
# after RUN_TIMEOUT it is sent SIGTERM, and if it does not exit within
# RUN_KILL_AFTER it is SIGKILLed. A timed-out run exits non-zero (124), which the
# caller already treats as a failed attempt — the same signal the quarantine
# logic later consumes.
run_implement() {
  local slug="${1:-}"
  local prompt="/implement"
  [ -n "$slug" ] && prompt="/implement $slug"
  log "running $prompt in $CHECKOUT_DIR (timeout $RUN_TIMEOUT, kill after $RUN_KILL_AFTER)"
  local status=0
  ( cd "$CHECKOUT_DIR" \
      && timeout --kill-after="$RUN_KILL_AFTER" "$RUN_TIMEOUT" \
           "$CLAUDE_BIN" -p "$prompt" --dangerously-skip-permissions ) || status=$?
  # timeout exits 124 (SIGTERM) or 137 (SIGKILL after the grace) on a hang.
  case "$status" in
    124|137) log "run exceeded $RUN_TIMEOUT and was terminated (counts as a failed attempt)" ;;
  esac
  return "$status"
}

main() {
  if [ -z "$TARGET_REPO" ]; then
    log "error: TARGET_REPO is required (git remote URL of the target repository)"
    exit 2
  fi

  ensure_checkout

  local status=0
  run_implement || status=$?

  if [ "$status" -eq 0 ]; then
    log "run succeeded"
  else
    log "run failed (exit $status)"
  fi
  return "$status"
}

# Only run main when executed directly, so tests can source the functions.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
