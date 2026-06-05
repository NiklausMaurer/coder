# Autonomous implementation loop — one container per target repo.
#
# Bundles `git` + the Claude Code CLI + Nix, and runs bin/loop.sh as the
# entrypoint. Three paths are meant to be backed by volumes so they survive
# restarts:
#   /data/checkout  the repo checkout  (CHECKOUT_DIR — avoids a full re-clone)
#   /data/state     the retry-count state file's dir (STATE_FILE — keeps a
#                   quarantined poison-pill's failure count across restarts)
#   /nix            the Nix store — the target's dev-shell toolchain (the right
#                   Node, package manager, system deps) is built/downloaded here
#                   on first use; a volume keeps it warm across restarts.
#
# Runs as a non-root user on purpose: `claude --dangerously-skip-permissions`
# refuses to run as root, and the container/volume isolation is the real safety
# boundary (no prod creds, a repo-scoped git PAT, disposable checkout).
#
# Debian (glibc) base rather than Alpine so Claude Code's bundled ripgrep works
# without USE_BUILTIN_RIPGREP gymnastics. Node 22 satisfies the >=18 requirement
# *for the Claude CLI itself* — the target's own toolchain (which may need a quite
# different Node/runtime) comes from its flake's dev shell, not this base image.
FROM node:22-bookworm-slim

# git is used every iteration; ca-certificates for HTTPS clone/pull/push; jq
# narrates Claude's stream-json output into the loop's logs (see narrate_run);
# curl + xz-utils are needed by the single-user Nix installer below.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates jq curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI (installed as root into /usr/local, runnable by any user).
RUN npm install -g @anthropic-ai/claude-code

# Non-root user (see header). --create-home gives a writable HOME for git config,
# Claude's ~/.claude config/cache dir, and the per-user Nix profile.
RUN useradd --create-home --shell /bin/bash coder

# Nix: the harness carries Nix so each *target* can declare its own build/test
# toolchain in a flake.nix; the loop enters it with `nix develop` (see
# run_implement). We do a single-user (daemonless) install because a container
# has no systemd to run the Nix daemon, and own /nix by `coder` so that user can
# write the store. Flakes + the unified `nix` command are enabled globally.
RUN mkdir -m 0755 /nix && chown coder:coder /nix \
    && mkdir -p /etc/nix \
    && printf 'experimental-features = nix-command flakes\n' > /etc/nix/nix.conf

# Volume mount points, pre-created and owned by coder so a freshly-initialised
# named volume inherits that ownership (Docker seeds an empty named volume from
# the image dir at its mount path — including the base Nix store seeded into /nix
# by the install step below).
RUN mkdir -p /data/checkout /data/state && chown -R coder:coder /data

COPY bin/ /app/bin/
RUN chmod +x /app/bin/*.sh

ENV HOME=/home/coder \
    CHECKOUT_DIR=/data/checkout \
    STATE_FILE=/data/state/retry-counts \
    PATH=/home/coder/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

USER coder
WORKDIR /home/coder

# Single-user Nix install, as the coder user who owns /nix. Daemonless so it works
# without systemd; PATH (set above) points at the per-user profile so non-login,
# non-interactive shells find `nix` without sourcing the installer's profile.d.
RUN curl -L https://nixos.org/nix/install | sh -s -- --no-daemon

# No plugins are baked in on purpose: this image is repo-agnostic. Whichever Claude
# plugins a target repo's `/implement` needs are declared in that repo's
# `.claude/coder-plugins` manifest and installed at runtime by the loop's
# sync_plugins (into ~/.claude/plugins, after the first checkout). That keeps a
# frontend repo's frontend-design dependency in the frontend repo, not here — so
# one image can drive any target. See bin/run-once.sh:sync_plugins.

# The entrypoint wires credentials from the environment, then execs the loop.
ENTRYPOINT ["/app/bin/docker-entrypoint.sh"]
