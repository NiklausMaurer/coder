#!/usr/bin/env bash
#
# Onboard a target repository to the coder autonomous loop.
#
# The loop itself is repo-agnostic and owns none of the development process: it
# just runs `/implement` inside a checkout. For that to do anything, the target
# repo must carry the process artifacts the loop relies on — the `/implement`
# skill, the `slice-lander` agent, and the kanban-board/ columns. This script
# scaffolds those from setup/process-kit/ into a target repo *once*, so they get
# committed to the target's own history (reviewable, diffable, repo-specific) —
# rather than the loop injecting them at runtime (invisible, and unable to know
# the repo's build/test commands).
#
# Two artifacts, two portabilities:
#   - implement/SKILL.md  is process-generic and copied ~verbatim.
#   - slice-lander.md      is inherently repo-specific (it knows how to build and
#                          test THIS repo), so it ships as a template with
#                          `coder:autofill` blanks. With autofill on (default), we
#                          run `claude -p` in the target to fill them by reading
#                          the repo; otherwise the blanks stay as TODOs for a human.
#
# Usage:
#   setup/init-target.sh <path-to-target-repo> [--force] [--no-autofill]
#
# Configuration (environment variables, all with defaults):
#   TARGET_DIR     target repo working copy        (default: $1)
#   KIT_DIR        process-kit source              (default: <script dir>/process-kit)
#   FORCE          overwrite existing kit files    (default: 0; --force sets 1)
#   AUTOFILL       run claude to fill the blanks   (default: 1; --no-autofill sets 0)
#   CLAUDE_BIN     Claude CLI binary               (default: claude)
#
# This is a setup tool, NOT part of the loop — the loop never sources it.

set -euo pipefail

log() { printf '[init-target] %s\n' "$*" >&2; }

# --- Configuration -----------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="${KIT_DIR:-$SCRIPT_DIR/process-kit}"
TARGET_DIR="${TARGET_DIR:-}"
FORCE="${FORCE:-0}"
AUTOFILL="${AUTOFILL:-1}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

BOARD_COLUMNS=(01-backlog 02-refined 03-in-progress 04-user-verification)

# --- Steps -------------------------------------------------------------------

# Parse the positional target path and the two flags, leaving env-var defaults in
# place when a flag is absent (so callers/tests can configure either way).
parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force)       FORCE=1 ;;
      --no-autofill) AUTOFILL=0 ;;
      -h|--help)     usage; exit 0 ;;
      -*)            log "unknown flag: $1"; usage; exit 2 ;;
      *)             TARGET_DIR="$1" ;;
    esac
    shift
  done
}

usage() {
  printf 'usage: %s <path-to-target-repo> [--force] [--no-autofill]\n' "${BASH_SOURCE[0]}" >&2
}

# Copy one kit file into the target, creating parent dirs. Refuse to clobber an
# existing file unless FORCE — onboarding must never silently overwrite a repo's
# own implement skill or slice-lander (e.g. re-running against nikos).
install_file() {
  local src="$1" dest="$2"
  if [ -e "$dest" ] && [ "$FORCE" != "1" ]; then
    log "exists, skipping (use --force to overwrite): ${dest#"$TARGET_DIR"/}"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  log "installed ${dest#"$TARGET_DIR"/}"
}

# Install every skill and agent the kit carries, preserving the `.claude/`
# layout. The loop's hard preconditions are the `implement` skill + `slice-lander`
# agent; the rest (`add-story`, `refine`, `to-slices`, `grill-me`) are the
# human-driven queue-filling pipeline that produces refined stories — bundled for
# convenience, not used by the loop itself. Globbing means adding a kit skill
# needs no edit here.
install_artifacts() {
  local f rel
  for f in "$KIT_DIR"/.claude/skills/*/SKILL.md "$KIT_DIR"/.claude/agents/*.md; do
    [ -e "$f" ] || continue
    rel="${f#"$KIT_DIR"/}"
    install_file "$f" "$TARGET_DIR/$rel"
  done
}

# Ensure the kanban columns exist, each tracked by a .gitkeep so an empty column
# survives git. We only ever *add* missing columns and never touch their
# contents — a repo already running the process keeps all its in-flight stories.
ensure_board() {
  local col
  for col in "${BOARD_COLUMNS[@]}"; do
    local dir="$TARGET_DIR/kanban-board/$col"
    if [ -d "$dir" ]; then
      log "board column present: $col"
    else
      mkdir -p "$dir"
      : > "$dir/.gitkeep"
      log "created board column: $col"
    fi
  done
  # The process guide lives next to the board so anyone browsing it learns how the
  # whole story lifecycle works. Subject to the same no-clobber rule as the skills.
  install_file "$KIT_DIR/kanban-board/README.md" "$TARGET_DIR/kanban-board/README.md"
}

# Append the process-kit CLAUDE.md section to the target's root CLAUDE.md, unless
# it is already present (idempotent on re-run). We append rather than rewrite so
# the repo's own guidance is left untouched; if there is no CLAUDE.md yet we
# create one carrying just the section.
merge_claude_md() {
  local dest="$TARGET_DIR/CLAUDE.md"
  if [ -f "$dest" ] && grep -q 'coder:process-kit' "$dest"; then
    log "CLAUDE.md already documents the loop, skipping"
    return 0
  fi
  printf '\n' >> "$dest"
  cat "$KIT_DIR/CLAUDE.snippet.md" >> "$dest"
  log "appended loop section to CLAUDE.md"
}

# Fill the `coder:autofill` blanks in the scaffolded template by having Claude
# read the target repo. Runs headless inside the target so Claude sees the real
# CLAUDE.md, package manager, and test setup; --dangerously-skip-permissions lets
# it edit the two files non-interactively (same trust model as the loop — you are
# onboarding your own repo). Best-effort: a missing/unauthed CLI just leaves the
# TODO blanks for a human, which is a valid end state.
autofill() {
  if [ "$AUTOFILL" != "1" ]; then
    log "autofill disabled — slice-lander/implement keep their TODO blanks for you to fill"
    return 0
  fi
  if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    log "warning: '$CLAUDE_BIN' not found — skipping autofill, leaving TODO blanks"
    return 0
  fi
  log "autofilling repo-specific blanks with $CLAUDE_BIN (reading the target repo)…"
  local status=0
  ( cd "$TARGET_DIR" && "$CLAUDE_BIN" -p "$(autofill_prompt)" --dangerously-skip-permissions ) \
    || status=$?
  if [ "$status" -ne 0 ]; then
    log "warning: autofill run exited $status — review the TODO blanks manually"
  fi
}

# The instruction handed to Claude for the autofill pass. Kept as a function so
# it is easy to read and to override in tests.
autofill_prompt() {
  cat <<'PROMPT'
You are finishing a one-time scaffold that onboarded this repo to an autonomous
implementation loop. Two files were just added with placeholder blanks marked by
HTML comments `<!-- coder:autofill <key> -->` … `<!-- /coder:autofill -->`:

  .claude/agents/slice-lander.md    (keys: architecture, verify, commit-convention)
  .claude/skills/implement/SKILL.md (key: commit-convention)
  .claude/skills/refine/SKILL.md    (key: commit-convention)
  .claude/skills/accept-verification/SKILL.md (key: commit-convention)

Read this repo's root CLAUDE.md, package manifest, and test setup to learn the
truth, then replace ONLY the content between each marker pair (leave the marker
comments themselves in place):

- architecture: the architecture invariants and per-slice file/layout conventions
  a one-slice implementer must honor (layering, module boundaries, naming, where
  tests live, how files split per slice). Keep it to rules that, if broken, leak
  boundaries or diverge from existing structure.
- verify: the exact verification commands to run from the repo root, in order,
  inside a ```sh code block (e.g. typecheck → lint → test → build for this repo's
  package manager).
- commit-convention: replace the `{{COMMIT_CONVENTION}}` line with this repo's
  commit-message convention and trailer (look at `git log --oneline -10`); if the
  repo has no trailer convention, state the message style and drop the trailer.

Do not change anything else. Do not commit or push.
PROMPT
}

main() {
  parse_args "$@"

  if [ -z "$TARGET_DIR" ]; then
    log "error: target repo path is required"
    usage
    exit 2
  fi
  if [ ! -d "$TARGET_DIR/.git" ]; then
    log "error: $TARGET_DIR is not a git repository (onboarding commits to its history)"
    exit 2
  fi
  if [ ! -d "$KIT_DIR" ]; then
    log "error: process-kit not found at $KIT_DIR"
    exit 2
  fi

  log "onboarding $TARGET_DIR"
  install_artifacts
  ensure_board
  merge_claude_md
  autofill

  log "done. Next steps:"
  log "  1. Review the diff in $TARGET_DIR (esp. the slice-lander blanks)."
  log "  2. Commit & push the scaffold to the target repo."
  log "  3. Point the loop at it: run coder/setup/setup-env.sh, then 'docker compose up -d --build'."
}

# Only run main when executed directly, so tests can source the functions.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
