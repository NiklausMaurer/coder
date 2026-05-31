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

# --- Test: per-run timeout kills a hung run ----------------------------------
#
# Slice 05: a single /implement run is wrapped in a timeout so a hung session
# can't stall the loop. A stub that hangs past the limit must be killed at the
# limit and reported as a failed attempt (non-zero exit), not left running.

test_per_run_timeout() {
  local base; base="$(mktemp -d)"
  trap 'rm -rf "$base"' RETURN

  local remote; remote="$(make_fixture_remote "$base")"
  local stub="$base/stub"; mkdir -p "$stub"
  export RUN_LOG="$base/run.log"; : > "$RUN_LOG"

  # A fake claude that hangs forever (until signalled). `exec tail -f` replaces
  # the process so timeout's SIGTERM kills it cleanly; the line after exec — the
  # "finished" marker — is never reached, proving it was terminated mid-run.
  cat > "$stub/claude" <<'EOF'
#!/usr/bin/env bash
printf 'started\n' >> "$RUN_LOG"
exec tail -f /dev/null
printf 'finished\n' >> "$RUN_LOG"
EOF
  chmod +x "$stub/claude"

  local start end elapsed
  start="$(date +%s)"
  TARGET_REPO="file://$remote" \
  CHECKOUT_DIR="$base/checkout" \
  CLAUDE_BIN="$stub/claude" \
  RUN_TIMEOUT=2 RUN_KILL_AFTER=1 \
    bash "$RUNNER" >/dev/null 2>"$base/stderr.log"
  local rc=$?
  end="$(date +%s)"
  elapsed=$((end - start))

  [ "$rc" -ne 0 ] \
    && ok "a timed-out run is reported as a failed attempt (non-zero exit)" \
    || nope "expected non-zero exit on timeout, got $rc"

  # Killed at the ~2s limit, not left to hang indefinitely.
  [ "$elapsed" -lt 15 ] \
    && ok "the hung run is killed at the limit (${elapsed}s elapsed)" \
    || nope "run was not killed at the limit (${elapsed}s elapsed)"

  grep -qx "started" "$RUN_LOG" \
    && ok "the hung run actually started" \
    || nope "stub never started"

  ! grep -qx "finished" "$RUN_LOG" \
    && ok "the hung run was terminated mid-run, not left to complete" \
    || nope "hung run completed despite the timeout"
}

# --- Test: narrate top-level subagent invocations ----------------------------
#
# `/implement` runs headless, so the loop's only window into it is Claude's
# `--output-format stream-json` event stream. The runner narrates the *top-level*
# subagent spawns (the `slice-lander` agent) onto stdout while filtering out the
# subagent's own nested events (those carry a non-null `parent_tool_use_id`).

# Fake `claude` that emits a canned stream-json stream — one top-level Agent
# spawn and one nested one — then lands a slice. Echoes the stub dir.
make_fake_claude_streaming() {
  local base="$1"
  local stub="$base/stub"
  mkdir -p "$stub"
  cat > "$stub/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RUN_LOG"
# Top-level subagent spawn (parent_tool_use_id null) — should be narrated.
printf '%s\n' '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"slice-lander","description":"Land the slice"}}]}}'
# Nested spawn inside the subagent (parent set) — must be filtered out.
printf '%s\n' '{"type":"assistant","parent_tool_use_id":"toolu_abc","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"nested-helper","description":"do not show"}}]}}'
printf '%s\n' '{"type":"result","subtype":"success","result":"done landing"}'
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

test_narrates_subagent_invocations() {
  if ! command -v jq >/dev/null 2>&1; then
    ok "skipped — jq not installed (narration falls back to raw passthrough)"
    return
  fi

  local base; base="$(mktemp -d)"
  trap 'rm -rf "$base"' RETURN

  local remote; remote="$(make_fixture_remote "$base")"
  local stub;   stub="$(make_fake_claude_streaming "$base")"
  export RUN_LOG="$base/run.log"; : > "$RUN_LOG"

  TARGET_REPO="file://$remote" \
  CHECKOUT_DIR="$base/checkout" \
  CLAUDE_BIN="$stub/claude" \
    bash "$RUNNER" >"$base/stdout.log" 2>"$base/stderr.log"
  local rc=$?

  [ "$rc" -eq 0 ] && ok "exits 0 with stream-json output" || nope "expected exit 0, got $rc"

  grep -q -- "--output-format stream-json --verbose" "$RUN_LOG" \
    && ok "requests stream-json output" \
    || nope "did not request stream-json output"

  grep -q "subagent slice-lander: Land the slice" "$base/stdout.log" \
    && ok "narrates the top-level subagent invocation" \
    || nope "did not narrate the top-level subagent invocation"

  ! grep -q "nested-helper" "$base/stdout.log" \
    && ok "filters out the subagent's own nested events" \
    || nope "leaked a nested (parent_tool_use_id) event"
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
echo "test_per_run_timeout"; test_per_run_timeout
echo "test_narrates_subagent_invocations"; test_narrates_subagent_invocations
echo "test_requires_repo";    test_requires_repo

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
