#!/usr/bin/env bash
#
# Tests for bin/loop.sh.
#
# Self-contained bash harness (no bats). Builds fixture target repos, stubs the
# Claude CLI and `sleep`, runs the loop for a bounded number of iterations, and
# asserts on board draining and adaptive sleep behavior.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOP="$ROOT/bin/loop.sh"

PASS=0
FAIL=0

ok()   { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
nope() { printf '  FAIL - %s\n' "$1"; FAIL=$((FAIL + 1)); }

# Build a bare remote with `main` carrying a refined column of N stories
# (01-story-1 .. 0N-story-N) plus a .claude marker. Echoes the bare remote path.
make_fixture_remote() {
  local base="$1" n="$2"
  local remote="$base/remote.git"
  local seed="$base/seed"

  git init --quiet --bare "$remote"

  git init --quiet "$seed"
  git -C "$seed" config user.email test@example.com
  git -C "$seed" config user.name "Test"
  git -C "$seed" symbolic-ref HEAD refs/heads/main
  local i
  for i in $(seq 1 "$n"); do
    mkdir -p "$seed/kanban-board/02-refined/0${i}-story-${i}"
    printf 'story %s\n' "$i" > "$seed/kanban-board/02-refined/0${i}-story-${i}/story.md"
  done
  mkdir -p "$seed/.claude"
  printf 'pretend skill\n' > "$seed/.claude/marker"
  git -C "$seed" add -A
  git -C "$seed" commit --quiet -m "seed: $n refined stories"
  git -C "$seed" push --quiet "$remote" main

  rm -rf "$seed"
  printf '%s' "$remote"
}

# Stub dir with a fake `claude` (no-slug /implement drains the lowest refined
# story: removes it, commits, pushes) and a fake `sleep` that records durations
# instead of waiting. Echoes the stub dir.
make_stubs() {
  local base="$1"
  local stub="$base/stub"
  mkdir -p "$stub"

  cat > "$stub/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RUN_LOG"
dir="kanban-board/02-refined"
lowest="$(find "$dir" -mindepth 1 -maxdepth 1 -type d | sort | head -n1)"
if [ -n "$lowest" ]; then
  git rm -rq "$lowest"
  git config user.email implement@example.com
  git config user.name "Implement"
  git commit --quiet -m "land: $(basename "$lowest")"
  git push --quiet origin HEAD:main
fi
EOF
  chmod +x "$stub/claude"

  cat > "$stub/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$SLEEP_LOG"
EOF
  chmod +x "$stub/sleep"

  printf '%s' "$stub"
}

count_remote_refined() {
  local remote="$1"
  git --git-dir="$remote" ls-tree -r --name-only main \
    | grep -c '^kanban-board/02-refined/.*/' || true
}

# --- Test: drain a 3-story column, then settle into idle ----------------------

test_drain_then_idle() {
  local base; base="$(mktemp -d)"
  trap 'rm -rf "$base"' RETURN

  local remote; remote="$(make_fixture_remote "$base" 3)"
  local stub;   stub="$(make_stubs "$base")"
  export RUN_LOG="$base/run.log"; : > "$RUN_LOG"
  export SLEEP_LOG="$base/sleep.log"; : > "$SLEEP_LOG"

  TARGET_REPO="file://$remote" \
  CHECKOUT_DIR="$base/checkout" \
  CLAUDE_BIN="$stub/claude" \
  WORK_SLEEP=3 IDLE_SLEEP=60 \
  MAX_ITERATIONS=5 \
  PATH="$stub:$PATH" \
    bash "$LOOP" >/dev/null 2>"$base/stderr.log"
  local rc=$?

  [ "$rc" -eq 0 ] && ok "loop exits 0 after bounded iterations" || nope "expected exit 0, got $rc"

  # 3 stories -> exactly 3 /implement invocations (one per work iteration).
  local runs; runs="$(wc -l < "$RUN_LOG" | tr -d '[:space:]')"
  [ "$runs" -eq 3 ] \
    && ok "one /implement per story: 3 invocations for 3 stories" \
    || nope "expected 3 invocations, got $runs"

  # Each invocation is the no-slug form (no story slug argument).
  if grep -qx -- "-p /implement --dangerously-skip-permissions" "$RUN_LOG" \
     && ! grep -q -- "/implement [0-9]" "$RUN_LOG"; then
    ok "invocations use the no-slug /implement form"
  else
    nope "invocations were not the no-slug form"
  fi

  # Column fully drained on the remote.
  local left; left="$(count_remote_refined "$remote")"
  [ "$left" -eq 0 ] \
    && ok "refined column is fully drained on the remote" \
    || nope "expected 0 refined stories left, got $left"

  # Adaptive sleep: short (3) after each of 3 work iterations, long (60) after
  # each of 2 idle iterations. This single sequence proves short-after-work,
  # long-after-idle, and one-story-per-pull all at once.
  local seq; seq="$(tr '\n' ' ' < "$SLEEP_LOG")"
  [ "$seq" = "3 3 3 60 60 " ] \
    && ok "adaptive sleep: short after work (3x3s), long after idle (2x60s)" \
    || nope "unexpected sleep sequence: [$seq]"
}

# --- Test: empty column idles without invoking /implement --------------------

test_idle_no_work() {
  local base; base="$(mktemp -d)"
  trap 'rm -rf "$base"' RETURN

  local remote; remote="$(make_fixture_remote "$base" 0)"
  local stub;   stub="$(make_stubs "$base")"
  export RUN_LOG="$base/run.log"; : > "$RUN_LOG"
  export SLEEP_LOG="$base/sleep.log"; : > "$SLEEP_LOG"

  TARGET_REPO="file://$remote" \
  CHECKOUT_DIR="$base/checkout" \
  CLAUDE_BIN="$stub/claude" \
  WORK_SLEEP=3 IDLE_SLEEP=60 \
  MAX_ITERATIONS=2 \
  PATH="$stub:$PATH" \
    bash "$LOOP" >/dev/null 2>"$base/stderr.log"
  local rc=$?

  [ "$rc" -eq 0 ] && ok "loop exits 0 when idle" || nope "expected exit 0, got $rc"

  local runs; runs="$(wc -l < "$RUN_LOG" | tr -d '[:space:]')"
  [ "$runs" -eq 0 ] \
    && ok "no /implement invocations when the column is empty" \
    || nope "expected 0 invocations, got $runs"

  local seq; seq="$(tr '\n' ' ' < "$SLEEP_LOG")"
  [ "$seq" = "60 60 " ] \
    && ok "idle iterations back off with the long interval" \
    || nope "unexpected sleep sequence: [$seq]"
}

# --- Test: missing config ----------------------------------------------------

test_requires_repo() {
  local base; base="$(mktemp -d)"
  trap 'rm -rf "$base"' RETURN

  TARGET_REPO="" CHECKOUT_DIR="$base/checkout" MAX_ITERATIONS=1 \
    bash "$LOOP" >/dev/null 2>"$base/stderr.log"
  local rc=$?

  [ "$rc" -eq 2 ] \
    && ok "fails when TARGET_REPO is unset" \
    || nope "expected exit 2 for missing TARGET_REPO, got $rc"
}

echo "test_drain_then_idle"; test_drain_then_idle
echo "test_idle_no_work";    test_idle_no_work
echo "test_requires_repo";   test_requires_repo

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
