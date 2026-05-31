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
#   3. Applies the retry cap to a resumed story (see below).
#   4. Sleeps adaptively: a short delay after doing work (drain a full column
#      quickly), a longer back-off when idle (poll for freshly pushed work).
#
# At most one story is attempted per pull, so each run works against the freshest
# remote state.
#
# Retry cap → quarantine. A story that keeps crashing `/implement` (as opposed to
# cleanly parking or completing) would otherwise be resumed forever, burning
# usage. After resuming a story, the loop checks the board: if the story is still
# sitting in `03-in-progress/`, the run crashed/timed out without completing or
# parking — a failed attempt. Consecutive failed attempts per story slug are
# tallied in a volume-persisted state file (so the count survives a process
# restart). A clean park to `04-user-verification/` or a successful completion
# (the story is no longer in `03-in-progress/`) clears the count. Once a story
# reaches MAX_RETRIES consecutive failures, the loop quarantines it: it parks the
# folder to `kanban-board/04-user-verification/` with a "crashed N×" note, commits
# and pushes that, and resets the count — reusing the existing human-needed column
# and clearing `03-in-progress/` so the loop keeps draining `02-refined/`.
#
# Configuration (environment variables) — in addition to those read by
# run-once.sh (TARGET_REPO, TARGET_BRANCH, CHECKOUT_DIR, CLAUDE_BIN):
#   WORK_SLEEP           seconds to sleep after a work iteration   (default: 5)
#   IDLE_SLEEP           seconds to sleep after an idle iteration  (default: 60)
#   KANBAN_REFINED       refined column path within the repo
#                                          (default: kanban-board/02-refined)
#   KANBAN_IN_PROGRESS   in-progress column path within the repo
#                                      (default: kanban-board/03-in-progress)
#   KANBAN_VERIFICATION  user-verification (quarantine) column path within the
#                          repo            (default: kanban-board/04-user-verification)
#   MAX_RETRIES          consecutive failed resumes before a story is quarantined
#                                                                   (default: 3)
#   STATE_FILE           volume-persisted per-slug failure counts
#                                          (default: $HOME/.coder/state/retry-counts)
#   MAX_ITERATIONS       stop after N iterations; empty = run forever (default: empty)

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
KANBAN_VERIFICATION="${KANBAN_VERIFICATION:-kanban-board/04-user-verification}"
MAX_RETRIES="${MAX_RETRIES:-3}"
STATE_FILE="${STATE_FILE:-$HOME/.coder/state/retry-counts}"
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

# --- Retry-cap state ---------------------------------------------------------
#
# The state file is a flat `slug<TAB>count` table, one line per tracked story. It
# lives outside the checkout (its own volume) so quarantine counts survive both a
# per-iteration tree reset and a full process restart.

# Echo the consecutive-failure count recorded for a slug (0 if none).
get_failure_count() {
  local slug="$1"
  [ -f "$STATE_FILE" ] || { echo 0; return; }
  local count
  count="$(awk -F'\t' -v s="$slug" '$1 == s { print $2 }' "$STATE_FILE")"
  echo "${count:-0}"
}

# Upsert the failure count for a slug, rewriting the state file atomically.
set_failure_count() {
  local slug="$1" count="$2"
  mkdir -p "$(dirname "$STATE_FILE")"
  local tmp
  tmp="$(mktemp)"
  [ -f "$STATE_FILE" ] && awk -F'\t' -v s="$slug" '$1 != s' "$STATE_FILE" > "$tmp"
  printf '%s\t%s\n' "$slug" "$count" >> "$tmp"
  mv "$tmp" "$STATE_FILE"
}

# Drop any recorded count for a slug (a clean park or completion resets it).
clear_failure_count() {
  local slug="$1"
  [ -f "$STATE_FILE" ] || return 0
  local tmp
  tmp="$(mktemp)"
  awk -F'\t' -v s="$slug" '$1 != s' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

# Park a poison-pill story — one that has crashed MAX_RETRIES times in a row
# without completing or parking — to the user-verification column with a note,
# clearing it from in-progress so the loop can keep draining. Any crash leftovers
# are discarded first (the same dirty-tree hygiene as ensure_checkout) so the
# commit carries only the move plus the note; committed history is never
# rewritten. The loop stamps its own committer identity inline rather than
# mutating the repo's git config.
quarantine_story() {
  local slug="$1" count="$2"
  local src="$KANBAN_IN_PROGRESS/$slug"
  local dst="$KANBAN_VERIFICATION/$slug"
  log "quarantining $slug after $count consecutive failed attempts -> $KANBAN_VERIFICATION"
  (
    cd "$CHECKOUT_DIR" || exit 1
    git reset --hard --quiet
    git clean -fd --quiet
    mkdir -p "$KANBAN_VERIFICATION"
    git mv "$src" "$dst"
    printf 'Quarantined by the autonomous loop: `/implement` crashed %s times in a row without completing or parking this story. It needs a human.\n' \
      "$count" > "$dst/QUARANTINE.md"
    git add "$dst/QUARANTINE.md"
    git -c user.email=coder@autonomous-loop -c user.name='coder (autonomous loop)' \
      commit --quiet -m "quarantine: $slug crashed ${count}x"
    git push --quiet origin "HEAD:$TARGET_BRANCH"
  )
}

# After resuming a stranded story, apply the retry-cap policy. The board is the
# signal: if the story is still in `03-in-progress/`, the run crashed/timed out
# without completing or parking — a failed attempt, so bump the count and
# quarantine once it hits the cap. Otherwise the story completed or was cleanly
# parked, so its count resets.
handle_resume_outcome() {
  local slug="$1"
  if [ -d "$CHECKOUT_DIR/$KANBAN_IN_PROGRESS/$slug" ]; then
    local count
    count="$(get_failure_count "$slug")"
    count=$((count + 1))
    if [ "$count" -ge "$MAX_RETRIES" ]; then
      log "$slug failed $count consecutive attempts (cap $MAX_RETRIES); quarantining"
      quarantine_story "$slug" "$count"
      clear_failure_count "$slug"
    else
      set_failure_count "$slug" "$count"
      log "$slug failed attempt $count/$MAX_RETRIES; will retry next iteration"
    fi
  else
    clear_failure_count "$slug"
  fi
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
    handle_resume_outcome "$resume"
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
