# Autonomous implementation loop — one container per target repo.
#
# Bundles `git` + the Claude Code CLI and runs bin/loop.sh as the entrypoint.
# Two paths are meant to be backed by volumes so they survive restarts:
#   /data/checkout  the repo checkout  (CHECKOUT_DIR — avoids a full re-clone)
#   /data/state     the retry-count state file's dir (STATE_FILE — keeps a
#                   quarantined poison-pill's failure count across restarts)
#
# Runs as a non-root user on purpose: `claude --dangerously-skip-permissions`
# refuses to run as root, and the container/volume isolation is the real safety
# boundary (no prod creds, a repo-scoped git PAT, disposable checkout).
#
# Debian (glibc) base rather than Alpine so Claude Code's bundled ripgrep works
# without USE_BUILTIN_RIPGREP gymnastics. Node 22 satisfies the >=18 requirement.
FROM node:22-bookworm-slim

# git is used every iteration; ca-certificates for HTTPS clone/pull/push; jq
# narrates Claude's stream-json output into the loop's logs (see narrate_run).
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates jq \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI (installed as root into /usr/local, runnable by any user).
RUN npm install -g @anthropic-ai/claude-code

# Non-root user (see header). --create-home gives a writable HOME for git config
# and Claude's ~/.claude config/cache dir.
RUN useradd --create-home --shell /bin/bash coder

# Volume mount points, pre-created and owned by coder so a freshly-initialised
# named volume inherits that ownership (Docker seeds an empty named volume from
# the image dir at its mount path).
RUN mkdir -p /data/checkout /data/state && chown -R coder:coder /data

COPY bin/ /app/bin/
RUN chmod +x /app/bin/*.sh

ENV HOME=/home/coder \
    CHECKOUT_DIR=/data/checkout \
    STATE_FILE=/data/state/retry-counts

USER coder
WORKDIR /home/coder

# No plugins are baked in on purpose: this image is repo-agnostic. Whichever Claude
# plugins a target repo's `/implement` needs are declared in that repo's
# `.claude/coder-plugins` manifest and installed at runtime by the loop's
# sync_plugins (into ~/.claude/plugins, after the first checkout). That keeps a
# frontend repo's frontend-design dependency in the frontend repo, not here — so
# one image can drive any target. See bin/run-once.sh:sync_plugins.

# The entrypoint wires credentials from the environment, then execs the loop.
ENTRYPOINT ["/app/bin/docker-entrypoint.sh"]
