#!/usr/bin/env bash
#
# Interactive wizard that scaffolds a *target directory* — the deployment unit of
# the loop. The coder repo builds an image; a target directory lives outside it
# (e.g. `~/coder/nikos/`) and holds the two files needed to run one container
# against one repo:
#
#   <dir>/.env                per-target config + secrets (owner-only)
#   <dir>/docker-compose.yml  copied verbatim from setup/target-template/
#
# Both are written together on purpose: a `.env` with no compose file (or a
# compose file left over from another target) is the failure mode hand-copying
# produces. There are only three required keys (TARGET_REPO,
# CLAUDE_CODE_OAUTH_TOKEN, GIT_PAT); everything else has a built-in default, so
# this walks you through the three and lets you accept defaults for the rest.
#
# The DIRECTORY NAME becomes the Compose project name, which namespaces the
# container and all three volumes — so we validate it rather than let a surprise
# like `~/coder/My_Repo` show up later as unexplained volumes.
#
# Mirrors setup/target-template/.env.example (the source of truth for the config
# matrix). Secrets are read without echo and never printed back.
#
# This is a setup tool, NOT part of the loop — the loop never sources it.
#
# Usage:
#   setup/setup-env.sh ~/coder/nikos
#   TARGET_DIR=~/coder/nikos setup/setup-env.sh

set -euo pipefail

log() { printf '[setup-env] %s\n' "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${TEMPLATE_DIR:-$SCRIPT_DIR/target-template}"
TARGET_DIR="${TARGET_DIR:-${1:-}}"
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

# Compose derives the project name from the directory name, lowercasing it and
# stripping anything outside [a-z0-9_-]. So `~/coder/My_Repo` silently becomes
# project `my_repo` — and the volumes it creates look unrelated to the directory
# you are standing in. Refuse names that would not survive that mangling intact.
check_project_name() {
  local name="$1"
  if [ "$name" != "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')" ] \
     || [ -z "$name" ]; then
    log "refusing '$name': the directory name becomes the Compose project name,"
    log "which must be lowercase [a-z0-9_-] — pick a clean slug (e.g. 'nikos')."
    exit 1
  fi
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
  if [ -z "$TARGET_DIR" ]; then
    log "usage: setup/setup-env.sh <target-dir>   (e.g. ~/coder/nikos)"
    log "the directory holds one target's .env + docker-compose.yml, and lives"
    log "outside the coder repo — this repo only builds the image."
    exit 1
  fi

  # Resolve to an absolute path before validating: the project name comes from the
  # final path component, and a trailing slash or a relative path would confuse it.
  TARGET_DIR="${TARGET_DIR%/}"
  local project_name
  project_name="$(basename "$TARGET_DIR")"
  check_project_name "$project_name"

  local env_file="$TARGET_DIR/.env"
  local compose_file="$TARGET_DIR/docker-compose.yml"

  log "This writes $env_file and $compose_file."
  log "Compose project name will be '$project_name' (from the directory name)."
  log "Required: TARGET_REPO, CLAUDE_CODE_OAUTH_TOKEN, GIT_PAT."

  if [ -f "$env_file" ]; then
    if ! ask_yes_no "$env_file exists — overwrite (a .bak backup is kept)?"; then
      log "aborted; left $TARGET_DIR untouched"
      exit 0
    fi
    cp "$env_file" "$env_file.bak"
    log "backed up existing .env to $env_file.bak"
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

  # --- Optional (defaults match target-template/.env.example / loop built-ins) ---
  local target_branch git_username git_user_name git_user_email run_timeout
  log "The rest are optional — press Enter to accept the shown default."
  target_branch="$(ask 'TARGET_BRANCH' 'main')"
  git_username="$(ask 'GIT_USERNAME (paired with GIT_PAT)' 'x-access-token')"
  git_user_name="$(ask 'GIT_USER_NAME (committer name)' 'coder (autonomous loop)')"
  git_user_email="$(ask 'GIT_USER_EMAIL (committer email)' 'coder@autonomous-loop')"
  run_timeout="$(ask 'RUN_TIMEOUT (max wall-clock per /implement run)' '30m')"

  # 077 covers both files and the directory itself — .env holds a Claude token and
  # a git PAT, so nothing here should be group- or world-readable.
  umask 077
  mkdir -p "$TARGET_DIR"
  cat > "$env_file" <<EOF
# Written by setup/setup-env.sh for Compose project '$project_name'.
# See setup/target-template/.env.example in the coder repo for the full config matrix.

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

  # Copied verbatim, not generated: the compose file is target-independent —
  # everything that varies (project, container, volume names) is derived by Compose
  # from the directory name. Nothing in it needs substituting.
  cp "$TEMPLATE_DIR/docker-compose.yml" "$compose_file"

  log "wrote $env_file (owner-only) and $compose_file"
  if [ -z "$oauth_token" ] || [ -z "$git_pat" ]; then
    log "warning: a required secret was left blank — the loop won't authenticate until you fill it."
  fi
  log "next: build the image in the coder repo (docker build -t coder .), then:"
  log "  cd $TARGET_DIR && docker compose up -d && docker compose logs -f"
}

# Only run main when executed directly, so the helpers can be sourced in tests.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
