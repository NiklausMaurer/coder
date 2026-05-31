#!/usr/bin/env bash
#
# Tests for bin/run-once.sh.
#
# No bats dependency: a self-contained bash harness. Each test builds a fixture
# "target repo" (a bare remote + seeded main branch carrying a refined story and
# a kanban board), stubs the Claude CLI with a fake `/implement`, runs the
# runner, and asserts on the outcome.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/bin/run-once.sh"

PASS=0
FAIL=0

ok()   { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
nope() { printf '  FAIL - %s\n' "$1"; FAIL=$((FAIL + 1)); }

# Build a bare remote with a main branch that carries a kanban board holding one
# refined story. Echoes the bare remote path.
make_fixture_remote() {
  local base="$1"
  local remote="$base/remote.git"
  local seed="$base/seed"

  git init --quiet --bare "$remote"

  git init --quiet "$seed"
  git -C "$seed" config user.email test@example.com
  git -C "$seed" config user.name "Test"
  git -C "$seed" symbolic-ref HEAD refs/heads/main
  mkdir -p "$seed/kanban-board/02-refined/01-some-story"
  printf 'a refined story\n' > "$seed/kanban-board/02-refined/01-some-story/story.md"
  mkdir -p "$seed/.claude"
  printf 'pretend skill\n' > "$seed/.claude/marker"
  git -C "$seed" add -A
  git -C "$seed" commit --quiet -m "seed: refined story + board"
  git -C "$seed" push --quiet "$remote" main

  rm -rf "$seed"
  printf '%s' "$remote"
}

# Write a fake `claude` onto a stub dir that, on `-p /implement`, simulates a
# landed slice: it commits a change and pushes it. Echoes the stub dir.
make_fake_claude_landing() {
  local base="$1"
  local stub="$base/stub"
  mkdir -p "$stub"
  cat > "$stub/claude" <<'EOF'
#!/usr/bin/env bash
# Fake /implement that "lands a slice": record invocation, commit, push.
printf '%s\n' "$*" >> "$RUN_LOG"
pwd >> "$RUN_LOG"
git config user.email implement@example.com
git config user.name "Implement"
printf 'done\n' > IMPLEMENTED
git add -A
git commit --quiet -m "land: slice done"
git push --quiet origin HEAD:main
EOF
  chmod +x "$stub/claude"
  printf '%s' "$stub"
}

# --- Test: clone, run, land --------------------------------------------------

test_clone_run_land() {
  local base; base="$(mktemp -d)"
  trap 'rm -rf "$base"' RETURN

  local remote; remote="$(make_fixture_remote "$base")"
  local stub;   stub="$(make_fake_claude_landing "$base")"
  export RUN_LOG="$base/run.log"
  : > "$RUN_LOG"

  TARGET_REPO="file://$remote" \
  TARGET_BRANCH="main" \
  CHECKOUT_DIR="$base/checkout" \
  CLAUDE_BIN="$stub/claude" \
  PATH="$stub:$PATH" \
    bash "$RUNNER" >/dev/null 2>"$base/stderr.log"
  local rc=$?

  [ "$rc" -eq 0 ] && ok "exits 0 on a successful run" || nope "expected exit 0, got $rc"

  [ -d "$base/checkout/.git" ] && ok "creates a local checkout" || nope "no checkout created"

  grep -q -- "-p /implement --dangerously-skip-permissions" "$RUN_LOG" \
    && ok "invokes /implement with --dangerously-skip-permissions" \
    || nope "did not invoke /implement with the expected flags"

  grep -qx "$base/checkout" "$RUN_LOG" \
    && ok "runs /implement inside the checkout" \
    || nope "did not run /implement inside the checkout"

  # The landed slice must have reached the remote (commits + pushes).
  local remote_files
  remote_files="$(git --git-dir="$remote" ls-tree -r --name-only main)"
  printf '%s\n' "$remote_files" | grep -qx "IMPLEMENTED" \
    && ok "landed slice is committed and pushed to the remote" \
    || nope "landed change did not reach the remote"

  # Runner must not have added skills/agents/board structure itself: the only new
  # remote file beyond the seed is the fake-implement's own IMPLEMENTED.
  local injected
  injected="$(printf '%s\n' "$remote_files" | grep -vE '^(IMPLEMENTED|kanban-board/|\.claude/)' || true)"
  [ -z "$injected" ] \
    && ok "runner does not inject skills/agents/kanban structure" \
    || nope "runner introduced unexpected files: $injected"
}

# --- Test: update existing checkout instead of re-cloning ---------------------

test_update_existing() {
  local base; base="$(mktemp -d)"
  trap 'rm -rf "$base"' RETURN

  local remote; remote="$(make_fixture_remote "$base")"
  local stub;   stub="$(make_fake_claude_landing "$base")"
  export RUN_LOG="$base/run.log"
  : > "$RUN_LOG"

  # Pre-clone so the checkout already exists.
  git clone --quiet "file://$remote" "$base/checkout"

  TARGET_REPO="file://$remote" \
  CHECKOUT_DIR="$base/checkout" \
  CLAUDE_BIN="$stub/claude" \
    bash "$RUNNER" >/dev/null 2>"$base/stderr.log"
  local rc=$?

  [ "$rc" -eq 0 ] && ok "exits 0 when updating an existing checkout" || nope "expected exit 0, got $rc"
  grep -q "updating existing checkout" "$base/stderr.log" \
    && ok "updates the existing checkout (no re-clone)" \
    || nope "did not take the update path"
}

# --- Test: dirty-tree hygiene — discard leftovers before pulling -------------
#
# Slice 04: a crashed run can leave uncommitted changes / untracked files in the
# checkout. Before pulling, the runner must `git reset --hard` + `git clean -fd`
# so a fast-forward that would otherwise fail ("would be overwritten") succeeds,
# without ever rewriting committed history.

test_dirty_tree_hygiene() {
  local base; base="$(mktemp -d)"
  trap 'rm -rf "$base"' RETURN

  local remote; remote="$(make_fixture_remote "$base")"
  local stub;   stub="$(make_fake_claude_landing "$base")"
  export RUN_LOG="$base/run.log"; : > "$RUN_LOG"

  # Pre-clone so the runner takes the existing-checkout path.
  git clone --quiet "file://$remote" "$base/checkout"

  # Advance the remote (throwaway clone): change a tracked file and add a new
  # one, so the runner's pull has something to fast-forward onto.
  git clone --quiet "file://$remote" "$base/advance"
  git -C "$base/advance" config user.email adv@example.com
  git -C "$base/advance" config user.name "Adv"
  printf 'updated by remote\n' > "$base/advance/.claude/marker"
  printf 'new remote file\n'   > "$base/advance/REMOTE_NEW"
  git -C "$base/advance" add -A
  git -C "$base/advance" commit --quiet -m "advance: remote moved on"
  git -C "$base/advance" push --quiet origin HEAD:main

  # Dirty the checkout so a plain `pull --ff-only` would refuse:
  #  - uncommitted edit to a tracked file the remote also changed,
  #  - untracked file that collides with one the remote commit introduces,
  #  - a stray untracked file with no remote counterpart.
  printf 'local crash leftover\n' > "$base/checkout/.claude/marker"
  printf 'local untracked\n'       > "$base/checkout/REMOTE_NEW"
  printf 'stray\n'                 > "$base/checkout/STRAY_UNTRACKED"

  # Committed HEAD before the run — cleanup must not rewrite it.
  local head_before; head_before="$(git -C "$base/checkout" rev-parse HEAD)"

  TARGET_REPO="file://$remote" \
  CHECKOUT_DIR="$base/checkout" \
  CLAUDE_BIN="$stub/claude" \
    bash "$RUNNER" >/dev/null 2>"$base/stderr.log"
  local rc=$?

  [ "$rc" -eq 0 ] \
    && ok "exits 0 despite a dirty tree that would block a plain pull" \
    || nope "expected exit 0, got $rc"

  # Fast-forward succeeded: the remote's change to the tracked file is now live.
  grep -qx "updated by remote" "$base/checkout/.claude/marker" \
    && ok "discards uncommitted changes and fast-forwards onto the remote" \
    || nope "checkout did not pick up the remote change to the tracked file"

  # Untracked stray with no remote counterpart is gone (git clean -fd).
  [ ! -e "$base/checkout/STRAY_UNTRACKED" ] \
    && ok "removes untracked leftovers with git clean -fd" \
    || nope "untracked leftover survived the cleanup"

  # Cleanup never rewrites committed history: HEAD only moved forward, with the
  # pre-run commit still an ancestor (fast-forward, no rebase/amend/force).
  local new_head; new_head="$(git -C "$base/checkout" rev-parse HEAD)"
  if git -C "$base/checkout" merge-base --is-ancestor "$head_before" "$new_head"; then
    ok "preserves committed history across cleanup + pull (fast-forward only)"
  else
    nope "committed history was rewritten by the cleanup"
  fi
}

# --- Test: surfaces failure --------------------------------------------------

test_surfaces_failure() {
  local base; base="$(mktemp -d)"
  trap 'rm -rf "$base"' RETURN

  local remote; remote="$(make_fixture_remote "$base")"
  local stub="$base/stub"; mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$stub/claude"
  chmod +x "$stub/claude"

  TARGET_REPO="file://$remote" \
  CHECKOUT_DIR="$base/checkout" \
  CLAUDE_BIN="$stub/claude" \
    bash "$RUNNER" >/dev/null 2>"$base/stderr.log"
  local rc=$?

  [ "$rc" -eq 7 ] \
    && ok "propagates the /implement failure exit code" \
    || nope "expected exit 7, got $rc"
}

# --- Test: missing config ----------------------------------------------------

test_requires_repo() {
  local base; base="$(mktemp -d)"
  trap 'rm -rf "$base"' RETURN

  TARGET_REPO="" CHECKOUT_DIR="$base/checkout" \
    bash "$RUNNER" >/dev/null 2>"$base/stderr.log"
  local rc=$?

  [ "$rc" -eq 2 ] \
    && ok "fails when TARGET_REPO is unset" \
    || nope "expected exit 2 for missing TARGET_REPO, got $rc"
}

echo "test_clone_run_land";   test_clone_run_land
echo "test_update_existing";  test_update_existing
echo "test_dirty_tree_hygiene"; test_dirty_tree_hygiene
echo "test_surfaces_failure"; test_surfaces_failure
echo "test_requires_repo";    test_requires_repo

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
