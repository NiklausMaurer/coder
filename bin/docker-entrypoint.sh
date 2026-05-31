#!/usr/bin/env bash
#
# Container entrypoint: wire credentials from the environment, then hand off to
# the loop. Kept separate from loop.sh so the loop itself stays repo-/host-
# agnostic and unit-testable outside Docker.
#
# Credentials (see README "Credentials"):
#   CLAUDE_CODE_OAUTH_TOKEN  Claude subscription token from `claude setup-token`.
#                            Consumed directly by `claude`; passed straight
#                            through the environment, not touched here.
#   GIT_PAT                  scoped HTTPS Personal Access Token for the target
#                            repo, used for git pull/push. Stored in git's
#                            credential store keyed to TARGET_REPO's host so every
#                            git call in the loop authenticates without the token
#                            ever appearing in a remote URL or in argv.
#   GIT_USERNAME             username paired with the PAT (default: x-access-token,
#                            which GitHub accepts for token auth).
#
# Committer identity for the commits `/implement` makes in the target repo —
# configurable, with defaults so a fresh container can commit at all:
#   GIT_USER_NAME, GIT_USER_EMAIL

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '[entrypoint] %s\n' "$*" >&2; }

# Wire the scoped HTTPS PAT into git's credential store, keyed to the host of
# TARGET_REPO so every git invocation in the loop authenticates transparently.
if [ -n "${GIT_PAT:-}" ] && [ -n "${TARGET_REPO:-}" ]; then
  # Derive the host: strip the scheme, any existing userinfo, then the path.
  no_scheme="${TARGET_REPO#*://}"
  host="${no_scheme#*@}"
  host="${host%%/*}"
  user="${GIT_USERNAME:-x-access-token}"
  printf 'https://%s:%s@%s\n' "$user" "$GIT_PAT" "$host" > "$HOME/.git-credentials"
  chmod 600 "$HOME/.git-credentials"
  git config --global credential.helper store
  log "wired git credentials for $host"
else
  log "GIT_PAT/TARGET_REPO not both set; git will use whatever credentials are already present"
fi

# /implement runs git commit inside the target repo; without an identity that
# fails. The loop's own quarantine commit stamps an identity inline, but this
# covers Claude's commits too.
git config --global user.name "${GIT_USER_NAME:-coder (autonomous loop)}"
git config --global user.email "${GIT_USER_EMAIL:-coder@autonomous-loop}"

# The loop owns an isolated checkout; accept it regardless of volume ownership
# so a host bind-mount can't trip git's dubious-ownership guard.
git config --global --add safe.directory '*'

exec "$SCRIPT_DIR/loop.sh" "$@"
