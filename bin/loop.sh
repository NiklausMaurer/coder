#!/usr/bin/env bash
#
# Continuous loop with board-driven adaptive sleep.
#
# Wraps the one-shot runner (bin/run-once.sh) in a loop that drains the target
# repo's `kanban-board/02-refined/` column and backs off when there is nothing to
# do. Each iteration:
#
#   1. Pulls the configured branch (ensure_checkout — clone first time, then
#      fast-forward).
#   2. Inspects the board to decide what to work on (resume-then-drain). The
#      board — not Claude's stdout — is the work/idle signal:
#        - a story in `kanban-board/03-in-progress/` → resume it via
#          `/implement <slug>` (self-healing: a previous run was killed or
#          crashed mid-story, stranding its folder here; the no-slug form would
#          never pick it back up),
#        - else a story in `kanban-board/02-refined/` → no-slug `/implement`
#          (drains the lowest `NN-` story),
#        - else the iteration is idle.
#      When several stories sit in a column, the lowest `NN-` prefix is chosen.
#   3. Sleeps adaptively: a short delay after doing work (drain a full column
#      quickly), a longer back-off when idle (poll for freshly pushed work).
#
# At most one story is attempted per pull, so each run works against the freshest
# remote state.
#
# Configuration (environment variables) — in addition to those read by
# run-once.sh (TARGET_REPO, TARGET_BRANCH, CHECKOUT_DIR, CLAUDE_BIN):
#   WORK_SLEEP          seconds to sleep after a work iteration   (default: 5)
#   IDLE_SLEEP          seconds to sleep after an idle iteration  (default: 60)
#   KANBAN_REFINED      refined column path within the repo
#                                          (default: kanban-board/02-refined)
#   KANBAN_IN_PROGRESS  in-progress column path within the repo
#                                      (default: kanban-board/03-in-progress)
#   MAX_ITERATIONS      stop after N iterations; empty = run forever (default: empty)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/run-once.sh
source "$SCRIPT_DIR/run-once.sh"

# Re-point logging at the loop while reusing run-once's helpers.
log() { printf '[loop] %s\n' "$*" >&2; }

# --- Configuration -----------------------------------------------------------

WORK_SLEEP="${WORK_SLEEP:-5}"
IDLE_SLEEP="${IDLE_SLEEP:-60}"
KANBAN_REFINED="${KANBAN_REFINED:-kanban-board/02-refined}"
KANBAN_IN_PROGRESS="${KANBAN_IN_PROGRESS:-kanban-board/03-in-progress}"
MAX_ITERATIONS="${MAX_ITERATIONS:-}"

# --- Steps -------------------------------------------------------------------

# Echo the number of story folders in the refined column. A story is an immediate
# subdirectory of the column (e.g. `01-some-story/`).
count_refined() {
  local dir="$CHECKOUT_DIR/$KANBAN_REFINED"
  if [ ! -d "$dir" ]; then
    echo 0
    return
  fi
  find "$dir" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]'
}

# Echo the slug of the lowest `NN-` story stranded in the in-progress column, or
# nothing if the column is empty/absent. A story is an immediate subdirectory of
# the column (e.g. `03-some-story/`).
in_progress_story() {
  local dir="$CHECKOUT_DIR/$KANBAN_IN_PROGRESS"
  [ -d "$dir" ] || return 0
  local lowest
  lowest="$(find "$dir" -mindepth 1 -maxdepth 1 -type d | sort | head -n1)"
  [ -n "$lowest" ] && basename "$lowest"
  return 0
}

do_sleep() {
  local secs="$1" reason="$2"
  log "sleeping ${secs}s (${reason})"
  sleep "$secs"
}

# One loop iteration: pull, inspect (resume-then-drain), (work or idle), sleep.
iterate() {
  ensure_checkout

  local resume
  resume="$(in_progress_story)"
  if [ -n "$resume" ]; then
    log "resuming stranded in-progress story: $resume"
    if ! run_implement "$resume"; then
      log "implement run failed; continuing to next iteration"
    fi
    do_sleep "$WORK_SLEEP" work
  elif [ "$(count_refined)" -gt 0 ]; then
    if ! run_implement; then
      log "implement run failed; continuing to next iteration"
    fi
    do_sleep "$WORK_SLEEP" work
  else
    log "no in-progress or refined stories; idle"
    do_sleep "$IDLE_SLEEP" idle
  fi
}

main() {
  if [ -z "$TARGET_REPO" ]; then
    log "error: TARGET_REPO is required (git remote URL of the target repository)"
    exit 2
  fi

  local iter=0
  while true; do
    iter=$((iter + 1))
    log "iteration $iter"
    iterate
    if [ -n "$MAX_ITERATIONS" ] && [ "$iter" -ge "$MAX_ITERATIONS" ]; then
      log "reached MAX_ITERATIONS=$MAX_ITERATIONS; stopping"
      break
    fi
  done
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
