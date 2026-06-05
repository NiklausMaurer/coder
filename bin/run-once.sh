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
#   PLUGIN_MANIFEST     path within the checkout where the target declares the
#                       Claude plugins its /implement needs   (default: .claude/coder-plugins)
#   PLUGIN_SYNC_MARKER  fingerprint of the last-installed manifest, to skip
#                       re-syncing an unchanged one        (default: $HOME/.coder/plugin-sync)
#   NIX_BIN             Nix binary used to enter a target's dev shell (default: nix)
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
PLUGIN_MANIFEST="${PLUGIN_MANIFEST:-.claude/coder-plugins}"
# Lives under $HOME on purpose — with Claude's plugin cache (~/.claude/plugins),
# NOT on a state volume. The two share a lifecycle: an image rebuild wipes the
# cache and the marker together, so the next boot re-installs from scratch.
PLUGIN_SYNC_MARKER="${PLUGIN_SYNC_MARKER:-$HOME/.coder/plugin-sync}"
NIX_BIN="${NIX_BIN:-nix}"

# --- Steps -------------------------------------------------------------------

# Ensure a local checkout of TARGET_BRANCH exists and is up to date. Clones when
# absent; on an existing checkout, force-converges the local branch onto the
# freshly-fetched remote tip and scrubs any crash leftovers.
#
# We `git reset --hard origin/$TARGET_BRANCH` (not `git pull --ff-only`) because
# the checkout is disposable and loop-owned. A crashed run can leave the local
# branch with a committed-but-unpushed slice; the next pull then sees diverged
# histories and aborts ("Not possible to fast-forward", exit 128), wedging the
# loop on every restart since the checkout volume outlives the container. A hard
# reset to the remote converges unconditionally, also discarding any uncommitted
# changes / untracked collisions in one step. This is safe because slice work is
# atomic-per-commit — anything not on the remote is incomplete slice work that
# re-runs from its `03-in-progress/` marker. It moves only the *local* branch
# pointer; pushed history is never rewritten (no rebase/amend/force).
ensure_checkout() {
  if [ -d "$CHECKOUT_DIR/.git" ]; then
    log "updating existing checkout at $CHECKOUT_DIR"
    git -C "$CHECKOUT_DIR" fetch --quiet origin "$TARGET_BRANCH"
    git -C "$CHECKOUT_DIR" checkout --quiet "$TARGET_BRANCH"
    git -C "$CHECKOUT_DIR" reset --hard --quiet "origin/$TARGET_BRANCH"
    git -C "$CHECKOUT_DIR" clean -fd --quiet
  else
    log "cloning $TARGET_REPO (branch $TARGET_BRANCH) into $CHECKOUT_DIR"
    mkdir -p "$(dirname "$CHECKOUT_DIR")"
    git clone --quiet --branch "$TARGET_BRANCH" "$TARGET_REPO" "$CHECKOUT_DIR"
  fi
}

# Install the Claude plugins the *target repo* declares, so the upcoming
# `/implement` run can use them. This is the one bit of target-specific tooling
# the harness can't get for free by being inside the checkout: skills and agents
# live in the tree and Claude loads them automatically, but plugins install into
# ~/.claude via an explicit marketplace-add + install. We keep the loop
# repo-agnostic by reading *what* to install from a manifest the target carries —
# the harness never names a plugin itself (so a frontend repo's frontend-design
# dependency lives in that repo, not baked into this generic image).
#
# Manifest (`$PLUGIN_MANIFEST` within the checkout) is line-based; each
# non-comment line is:
#     <plugin>@<marketplace>  <marketplace-git-url>
# The left token is exactly what `claude plugin install` takes; the right is what
# `claude plugin marketplace add` takes. Blank lines and `#` comments are ignored.
# A repo with no plugin needs simply omits the file (this is then a no-op).
#
# Cheap and idempotent: we fingerprint the manifest and skip when it is unchanged
# since the last successful sync into this plugin cache. A re-add of an existing
# marketplace is tolerated (`|| true`); an install that fails leaves the marker
# unwritten so it retries next iteration rather than being skipped forever.
sync_plugins() {
  local manifest="$CHECKOUT_DIR/$PLUGIN_MANIFEST"
  [ -f "$manifest" ] || return 0

  local fp
  fp="$(sha1sum "$manifest" | cut -d' ' -f1)"
  if [ -f "$PLUGIN_SYNC_MARKER" ] && [ "$(cat "$PLUGIN_SYNC_MARKER")" = "$fp" ]; then
    return 0
  fi

  log "syncing plugins declared in $PLUGIN_MANIFEST"
  local all_ok=1 plugin url
  while read -r plugin url _; do
    case "$plugin" in ''|\#*) continue ;; esac
    if [ -n "$url" ]; then
      "$CLAUDE_BIN" plugin marketplace add "$url" >/dev/null 2>&1 || true
    fi
    if "$CLAUDE_BIN" plugin install "$plugin" >/dev/null 2>&1; then
      log "  installed $plugin"
    else
      log "  warning: failed to install $plugin (will retry next iteration)"
      all_ok=0
    fi
  done < "$manifest"

  # Only fingerprint a fully-successful sync, so a transient failure retries.
  if [ "$all_ok" = 1 ]; then
    mkdir -p "$(dirname "$PLUGIN_SYNC_MARKER")"
    printf '%s\n' "$fp" > "$PLUGIN_SYNC_MARKER"
  fi
}

# Narrate a `claude --output-format stream-json` event stream into a few
# human-readable log lines. We run `/implement` headless, so the only window into
# what it is doing is this stream; the bit worth surfacing is the *top-level*
# subagent spawns (the `/implement` skill delegates landing to the `slice-lander`
# agent), plus the final result so the log isn't otherwise silent.
#
# Each spawn is an `assistant` event carrying an `Agent` tool_use block; the
# subagent's OWN nested events also stream but carry a non-null
# `parent_tool_use_id`, so filtering on `parent_tool_use_id==null` keeps only the
# top-level invocations. `fromjson?` tolerates any non-JSON line (e.g. a test
# stub's plain stdout) without erroring the pipe. If `jq` is unavailable we pass
# the raw stream through rather than swallow it.
narrate_run() {
  if ! command -v jq >/dev/null 2>&1; then cat; return; fi
  jq -Rr --unbuffered '
    (fromjson? // empty) as $e
    | if   ($e.type=="assistant" and ($e.parent_tool_use_id==null))
      then ($e.message.content[]?
            | select(.type=="tool_use" and .name=="Agent")
            | "[implement] subagent \(.input.subagent_type): \(.input.description)")
      elif $e.type=="result"
      then "[implement] result (\($e.subtype)): \(($e.result // "")|gsub("\n";" ")|.[0:200])"
      else empty
      end
  '
}

# Run `/implement` once, headless, with permissions bypassed (nobody is present
# to approve prompts; the container/VM is the safety boundary). Runs inside the
# checkout so Claude picks up the target repo's own skills and kanban board.
#
# With no argument, runs the no-slug form (drains the lowest `02-refined/`
# story). With a slug argument, runs `/implement <slug>` to resume that specific
# story (used by the loop to recover a story stranded in `03-in-progress/`).
#
# Toolchain: when the target ships a `flake.nix` and `nix` is available, the run
# is wrapped in `nix develop --command` so the story's verify gate (e.g.
# `pnpm typecheck/lint/test/build`) sees the *target's* declared toolchain — the
# right Node, package manager, and system deps — on PATH. The target owns the
# flake; the harness only enters it, so the image stays repo-agnostic (it carries
# Nix, not any one target's toolchain). A repo with no flake runs Claude directly
# on the image's base tooling (the simple-target case); if a flake is present but
# `nix` is missing (e.g. a host dev run) we warn and fall back to direct rather
# than wedge. `nix develop` also runs the flake's shellHook first, which is where
# a target repopulates deps wiped by the per-iteration `git clean -fd` (e.g.
# `pnpm install`) — keeping that target-specific step in the target, not here.
#
# Output is requested as `stream-json --verbose` and piped through narrate_run so
# the loop's logs show each top-level subagent invocation (see narrate_run). We
# preserve the *claude/timeout* exit status — not jq's — via PIPESTATUS, because
# the failed-attempt/quarantine logic keys off it (124/137 == timed out); `set
# +e` keeps the failing pipeline from tripping `set -e` before we read it.
#
# The run is bounded by `timeout` so a hung session can't stall the loop forever:
# after RUN_TIMEOUT it is sent SIGTERM, and if it does not exit within
# RUN_KILL_AFTER it is SIGKILLed. `timeout` wraps the whole `nix develop` tree so
# the kill reaches the dev shell *and* Claude. A timed-out run exits non-zero
# (124), which the caller already treats as a failed attempt — the same signal the
# quarantine logic later consumes.
run_implement() {
  local slug="${1:-}"
  local prompt="/implement"
  [ -n "$slug" ] && prompt="/implement $slug"
  log "running $prompt in $CHECKOUT_DIR (timeout $RUN_TIMEOUT, kill after $RUN_KILL_AFTER)"
  local status=0
  (
    cd "$CHECKOUT_DIR"
    set +e
    # Decide whether to enter the target's Nix dev shell (see header).
    local -a devshell=()
    if [ -f flake.nix ]; then
      if command -v "$NIX_BIN" >/dev/null 2>&1; then
        log "entering the target's Nix dev shell (flake.nix present)"
        devshell=( "$NIX_BIN" develop --command )
      else
        log "warning: flake.nix present but '$NIX_BIN' not found — running on base tooling"
      fi
    fi
    timeout --kill-after="$RUN_KILL_AFTER" "$RUN_TIMEOUT" \
      "${devshell[@]}" \
      "$CLAUDE_BIN" -p "$prompt" --dangerously-skip-permissions \
        --output-format stream-json --verbose \
      | narrate_run
    exit "${PIPESTATUS[0]}"
  ) || status=$?
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
  sync_plugins

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
