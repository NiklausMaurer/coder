#!/usr/bin/env bash
#
# Interactive wizard that writes coder's .env — the per-target-repo config the
# loop and docker-compose read. There are only three required keys (TARGET_REPO,
# CLAUDE_CODE_OAUTH_TOKEN, GIT_PAT); everything else has a built-in default, so
# this walks you through the three and lets you accept defaults for the rest.
#
# Mirrors .env.example (the source of truth for the config matrix). Writes to the
# coder repo root by default; secrets are read without echo and never printed back.
#
# Usage:
#   setup/setup-env.sh            # write ../  .env (repo root)
#   ENV_FILE=/path/.env setup/setup-env.sh

set -euo pipefail

log() { printf '[setup-env] %s\n' "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

# Prompt for a value, showing a default that is accepted on empty input.
# Reads from /dev/tty so prompts work even when stdout is redirected.
ask() {
  local prompt="$1" default="${2:-}" reply
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default" > /dev/tty
  else
    printf '%s: ' "$prompt" > /dev/tty
  fi
  read -r reply < /dev/tty || reply=""
  printf '%s' "${reply:-$default}"
}

# Prompt for a secret without echoing it.
ask_secret() {
  local prompt="$1" reply
  printf '%s: ' "$prompt" > /dev/tty
  read -rs reply < /dev/tty || reply=""
  printf '\n' > /dev/tty
  printf '%s' "$reply"
}

ask_yes_no() {
  local prompt="$1" reply
  printf '%s [y/N]: ' "$prompt" > /dev/tty
  read -r reply < /dev/tty || reply=""
  [[ "$reply" =~ ^[Yy] ]]
}

# Obtain the Claude subscription token. Offer to run `claude setup-token` (which
# prints one after an interactive login) or accept a pasted value — that token is
# the thing the loop authenticates Claude with, NOT an ANTHROPIC_API_KEY.
get_oauth_token() {
  if command -v "$CLAUDE_BIN" >/dev/null 2>&1 && ask_yes_no "Run '$CLAUDE_BIN setup-token' now to mint a token?"; then
    log "launching '$CLAUDE_BIN setup-token' — copy the printed token, then paste it below"
    "$CLAUDE_BIN" setup-token > /dev/tty 2>&1 || log "setup-token exited non-zero; paste a token you obtained elsewhere"
  fi
  ask_secret "CLAUDE_CODE_OAUTH_TOKEN (from 'claude setup-token')"
}

main() {
  log "This writes $ENV_FILE. Required: TARGET_REPO, CLAUDE_CODE_OAUTH_TOKEN, GIT_PAT."

  if [ -f "$ENV_FILE" ]; then
    if ! ask_yes_no "$ENV_FILE exists — overwrite (a .bak backup is kept)?"; then
      log "aborted; left $ENV_FILE untouched"
      exit 0
    fi
    cp "$ENV_FILE" "$ENV_FILE.bak"
    log "backed up existing .env to $ENV_FILE.bak"
  fi

  # --- Required ---
  local target_repo oauth_token git_pat
  target_repo="$(ask 'TARGET_REPO (git remote URL of the target repo)')"
  while [ -z "$target_repo" ]; do
    log "TARGET_REPO is required."
    target_repo="$(ask 'TARGET_REPO (git remote URL of the target repo)')"
  done
  oauth_token="$(get_oauth_token)"
  git_pat="$(ask_secret 'GIT_PAT (scoped HTTPS PAT for the target repo)')"

  # --- Optional (defaults match .env.example / loop built-ins) ---
  local target_branch git_username git_user_name git_user_email run_timeout
  log "The rest are optional — press Enter to accept the shown default."
  target_branch="$(ask 'TARGET_BRANCH' 'main')"
  git_username="$(ask 'GIT_USERNAME (paired with GIT_PAT)' 'x-access-token')"
  git_user_name="$(ask 'GIT_USER_NAME (committer name)' 'coder (autonomous loop)')"
  git_user_email="$(ask 'GIT_USER_EMAIL (committer email)' 'coder@autonomous-loop')"
  run_timeout="$(ask 'RUN_TIMEOUT (max wall-clock per /implement run)' '30m')"

  umask 077  # the file holds secrets — keep it owner-only
  cat > "$ENV_FILE" <<EOF
# Written by setup/setup-env.sh. See .env.example for the full config matrix.

# --- Required ---
TARGET_REPO=$target_repo
CLAUDE_CODE_OAUTH_TOKEN=$oauth_token
GIT_PAT=$git_pat

# --- Optional (defaults shown; loop falls back to these if unset) ---
TARGET_BRANCH=$target_branch
GIT_USERNAME=$git_username
GIT_USER_NAME=$git_user_name
GIT_USER_EMAIL=$git_user_email
RUN_TIMEOUT=$run_timeout

# Further loop tuning (uncomment to override defaults):
#WORK_SLEEP=5
#IDLE_SLEEP=60
#MAX_RETRIES=3
#RUN_KILL_AFTER=30s
#MAX_ITERATIONS=
EOF

  log "wrote $ENV_FILE (owner-only). Review it, then: docker compose up -d --build"
  if [ -z "$oauth_token" ] || [ -z "$git_pat" ]; then
    log "warning: a required secret was left blank — the loop won't authenticate until you fill it."
  fi
}

# Only run main when executed directly, so the helpers can be sourced in tests.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
