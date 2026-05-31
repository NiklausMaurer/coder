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
#
# Exit status is the `/implement` run's status, so a caller (or the future loop)
# can tell whether the run succeeded.

set -euo pipefail

log() { printf '[run-once] %s\n' "$*" >&2; }

# --- Configuration -----------------------------------------------------------

TARGET_REPO="${TARGET_REPO:-}"
TARGET_BRANCH="${TARGET_BRANCH:-main}"
CHECKOUT_DIR="${CHECKOUT_DIR:-$HOME/.coder/checkout}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

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
run_implement() {
  local slug="${1:-}"
  local prompt="/implement"
  [ -n "$slug" ] && prompt="/implement $slug"
  log "running $prompt in $CHECKOUT_DIR"
  ( cd "$CHECKOUT_DIR" && "$CLAUDE_BIN" -p "$prompt" --dangerously-skip-permissions )
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
