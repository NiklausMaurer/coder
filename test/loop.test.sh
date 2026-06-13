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
# (01-story-1 .. 0N-story-N) plus a .claude marker. An optional third argument
# seeds M stories into the in-progress column (01-wip-1 .. 0M-wip-M), simulating
# stories stranded by a crashed/killed previous run. Echoes the bare remote path.
make_fixture_remote() {
  local base="$1" n="$2" in_progress="${3:-0}"
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
  for i in $(seq 1 "$in_progress"); do
    mkdir -p "$seed/kanban-board/03-in-progress/0${i}-wip-${i}"
    printf 'wip %s\n' "$i" > "$seed/kanban-board/03-in-progress/0${i}-wip-${i}/story.md"
  done
  mkdir -p "$seed/.claude"
  printf 'pretend skill\n' > "$seed/.claude/marker"
  git -C "$seed" add -A
  git -C "$seed" commit --quiet -m "seed: $n refined stories"
  git -C "$seed" push --quiet "$remote" main

  rm -rf "$seed"
  printf '%s' "$remote"
}

# Stub dir with a fake `claude` and a fake `sleep` that records durations instead
# of waiting. Echoes the stub dir.
#
# The fake `claude` mirrors the two `/implement` forms the loop drives:
#   - no-slug `/implement`        → drain the lowest `02-refined/` story
#   - `/implement <slug>`         → resume (complete) `03-in-progress/<slug>`
# In both cases it removes the story folder, commits, and pushes.
make_stubs() {
  local base="$1"
  local stub="$base/stub"
  mkdir -p "$stub"

  cat > "$stub/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RUN_LOG"
git config user.email implement@example.com
git config user.name "Implement"

# The value passed to -p is "$2", e.g. "/implement" or "/implement 01-wip-1".
prompt="$2"
slug="${prompt#/implement}"
slug="${slug# }"

if [ -n "$slug" ]; then
  # Resume form: complete the named in-progress story.
  target="kanban-board/03-in-progress/$slug"
  if [ -d "$target" ]; then
    git rm -rq "$target"
    git commit --quiet -m "land: $slug"
    git push --quiet origin HEAD:main
  fi
else
  # No-slug drain form: land the lowest refined story.
  lowest="$(find kanban-board/02-refined -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -n1)"
  if [ -n "$lowest" ]; then
    git rm -rq "$lowest"
    git commit --quiet -m "land: $(basename "$lowest")"
    git push --quiet origin HEAD:main
  fi
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

count_remote_in_progress() {
  local remote="$1"
  git --git-dir="$remote" ls-tree -r --name-only main \
    | grep -c '^kanban-board/03-in-progress/.*/' || true
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

  # Each invocation is the no-slug form (no story slug argument). Anchored at the
  # line start so `/implement` is immediately followed by a flag, not a slug; the
  # trailing stream-json/verbose flags may follow.
  if grep -q -- "^-p /implement --dangerously-skip-permissions" "$RUN_LOG" \
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

# --- Test: a timed-out run is a failed attempt; the loop keeps going ----------
#
# Slice 05: when a run hangs past RUN_TIMEOUT it is killed and counts as a failed
# attempt. The loop must log the failure and continue to the next iteration
# rather than stalling. The hung story is never landed, so the column stays full.

test_timeout_continues_loop() {
  local base; base="$(mktemp -d)"
  trap 'rm -rf "$base"' RETURN

  local remote; remote="$(make_fixture_remote "$base" 1)"
  local stub="$base/stub"; mkdir -p "$stub"
  export RUN_LOG="$base/run.log"; : > "$RUN_LOG"
  export SLEEP_LOG="$base/sleep.log"; : > "$SLEEP_LOG"

  # A fake claude that hangs forever (until signalled), plus the recording sleep
  # stub. `exec tail -f` (not the stubbed `sleep`) gives a genuine block that
  # timeout must kill; the loop's own adaptive sleeps still resolve instantly.
  cat > "$stub/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RUN_LOG"
exec tail -f /dev/null
EOF
  chmod +x "$stub/claude"
  cat > "$stub/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$SLEEP_LOG"
EOF
  chmod +x "$stub/sleep"

  local start end elapsed
  start="$(date +%s)"
  TARGET_REPO="file://$remote" \
  CHECKOUT_DIR="$base/checkout" \
  CLAUDE_BIN="$stub/claude" \
  RUN_TIMEOUT=1 RUN_KILL_AFTER=1 \
  WORK_SLEEP=3 IDLE_SLEEP=60 \
  MAX_ITERATIONS=2 \
  PATH="$stub:$PATH" \
    bash "$LOOP" >/dev/null 2>"$base/stderr.log"
  local rc=$?
  end="$(date +%s)"
  elapsed=$((end - start))

  [ "$rc" -eq 0 ] && ok "loop exits 0 after timed-out iterations" || nope "expected exit 0, got $rc"

  # Both iterations ran (the loop did not stall on the first hang)...
  local runs; runs="$(wc -l < "$RUN_LOG" | tr -d '[:space:]')"
  [ "$runs" -eq 2 ] \
    && ok "loop continues to the next iteration after a timed-out run" \
    || nope "expected 2 invocations across 2 iterations, got $runs"

  # ...and each was killed at the ~1s limit, not left hanging.
  [ "$elapsed" -lt 20 ] \
    && ok "each hung run is killed at the timeout (${elapsed}s for 2 iterations)" \
    || nope "runs were not killed at the limit (${elapsed}s elapsed)"

  grep -q "continuing to next iteration" "$base/stderr.log" \
    && ok "the timed-out run is logged as a failed attempt" \
    || nope "loop did not log the failed attempt"

  # The hung story was never landed: the column stays full.
  local left; left="$(count_remote_refined "$remote")"
  [ "$left" -eq 1 ] \
    && ok "a hung run lands nothing; the story stays in the column" \
    || nope "expected 1 refined story left, got $left"
}

# --- Test: stdout narrates the story and its board outcome --------------------
#
# The loop announces the story it is working on (by name, on both the resume and
# the no-slug drain path) and, once the run finishes, where that story ended up,
# on *stdout* — separate from the operational log on stderr. The outcome is read
# from the board (the story folder is gone = fully landed), not from a commit
# range, so foreign commits the run integrates can never be misreported as slices.

test_progress_narrates_story_outcome() {
  local base; base="$(mktemp -d)"
  trap 'rm -rf "$base"' RETURN

  local remote; remote="$(make_fixture_remote "$base" 1)"
  local stub;   stub="$(make_stubs "$base")"
  export RUN_LOG="$base/run.log"; : > "$RUN_LOG"
  export SLEEP_LOG="$base/sleep.log"; : > "$SLEEP_LOG"

  TARGET_REPO="file://$remote" \
  CHECKOUT_DIR="$base/checkout" \
  CLAUDE_BIN="$stub/claude" \
  WORK_SLEEP=3 IDLE_SLEEP=60 \
  MAX_ITERATIONS=1 \
  PATH="$stub:$PATH" \
    bash "$LOOP" >"$base/stdout.log" 2>/dev/null

  # The drain path names the story it picked (the loop, not just Claude, says so).
  grep -q '^\[coder\] working on story: 01-story-1 (draining refined column)$' "$base/stdout.log" \
    && ok "stdout announces the story being drained, by name" \
    || nope "stdout did not announce the drained story"

  # The drain stub removes the story folder (every slice landed), so the board
  # shows it gone and the loop reports the story landed at the story level.
  grep -q '^\[coder\] landed story (all slices): 01-story-1$' "$base/stdout.log" \
    && ok "stdout reports the story landed once its folder is gone from the board" \
    || nope "stdout did not report the landed story"

  # No per-commit slice listing leaks back in — the loop narrates stories, not a
  # commit range (which is what swept foreign refine/backlog commits in before).
  grep -q '^\[coder\] landed slice:' "$base/stdout.log" \
    && nope "stdout still lists individual commits as landed slices" \
    || ok "no per-commit 'landed slice' lines — story-level narration only"

  # Narration goes to stdout, not the stderr plumbing channel.
  grep -q '^\[coder\]' "$base/stdout.log" \
    && ! grep -q '^\[loop\]' "$base/stdout.log" \
    && ok "progress narration is on stdout, separate from log() on stderr" \
    || nope "progress/log channels are not cleanly separated"
}

# --- Test: a run that lands nothing reports the story incomplete --------------
#
# A work iteration whose run commits nothing must say so at the story level. Here
# the poison stub crashes without touching the board, so the resumed story stays
# in 03-in-progress and the loop reports it incomplete (to be resumed), rather
# than inventing slice lines from an unmoved HEAD.

test_progress_incomplete_when_nothing_lands() {
  local base; base="$(mktemp -d)"
  trap 'rm -rf "$base"' RETURN

  local remote; remote="$(make_fixture_remote "$base" 0 1)"
  local stub;   stub="$(make_poison_stubs "$base")"
  export RUN_LOG="$base/run.log"; : > "$RUN_LOG"
  export SLEEP_LOG="$base/sleep.log"; : > "$SLEEP_LOG"

  TARGET_REPO="file://$remote" \
  CHECKOUT_DIR="$base/checkout" \
  CLAUDE_BIN="$stub/claude" \
  STATE_FILE="$base/state" \
  WORK_SLEEP=3 IDLE_SLEEP=60 \
  MAX_ITERATIONS=1 \
  PATH="$stub:$PATH" \
    bash "$LOOP" >"$base/stdout.log" 2>/dev/null

  grep -q '^\[coder\] story incomplete, will resume next iteration: 01-wip-1$' "$base/stdout.log" \
    && ok "a run that commits nothing reports the story incomplete" \
    || nope "expected an 'incomplete, will resume' line on stdout"
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

# --- Test: resume a stranded in-progress story before draining refined --------
#
# Simulates crash recovery: a previous run was killed mid-story, leaving its
# folder in `03-in-progress/`. The next iteration must resume that story (via the
# slug form) rather than draining `02-refined/`.

test_resume_before_drain() {
  local base; base="$(mktemp -d)"
  trap 'rm -rf "$base"' RETURN

  # 2 refined stories AND 1 stranded in-progress story.
  local remote; remote="$(make_fixture_remote "$base" 2 1)"
  local stub;   stub="$(make_stubs "$base")"
  export RUN_LOG="$base/run.log"; : > "$RUN_LOG"
  export SLEEP_LOG="$base/sleep.log"; : > "$SLEEP_LOG"

  TARGET_REPO="file://$remote" \
  CHECKOUT_DIR="$base/checkout" \
  CLAUDE_BIN="$stub/claude" \
  STATE_FILE="$base/state" \
  WORK_SLEEP=3 IDLE_SLEEP=60 \
  MAX_ITERATIONS=1 \
  PATH="$stub:$PATH" \
    bash "$LOOP" >/dev/null 2>"$base/stderr.log"
  local rc=$?

  [ "$rc" -eq 0 ] && ok "loop exits 0 after resuming" || nope "expected exit 0, got $rc"

  # The single iteration must resume the in-progress story, not drain refined.
  local first; first="$(head -n1 "$RUN_LOG")"
  [[ "$first" == "-p /implement 01-wip-1 --dangerously-skip-permissions"* ]] \
    && ok "first iteration resumes in-progress story via /implement <slug>" \
    || nope "expected resume of 01-wip-1, got: [$first]"

  # The resumed story is cleared from in-progress on the remote...
  local wip; wip="$(count_remote_in_progress "$remote")"
  [ "$wip" -eq 0 ] \
    && ok "resumed story is cleared from in-progress on the remote" \
    || nope "expected 0 in-progress stories left, got $wip"

  # ...while refined is left untouched (resume preferred over drain).
  local refined; refined="$(count_remote_refined "$remote")"
  [ "$refined" -eq 2 ] \
    && ok "refined column untouched while a story was in progress" \
    || nope "expected 2 refined stories left, got $refined"
}

# --- Test: lowest NN- in-progress story is resumed first ----------------------

test_resume_lowest_in_progress() {
  local base; base="$(mktemp -d)"
  trap 'rm -rf "$base"' RETURN

  # Two stranded in-progress stories: 01-wip-1 and 02-wip-2.
  local remote; remote="$(make_fixture_remote "$base" 0 2)"
  local stub;   stub="$(make_stubs "$base")"
  export RUN_LOG="$base/run.log"; : > "$RUN_LOG"
  export SLEEP_LOG="$base/sleep.log"; : > "$SLEEP_LOG"

  TARGET_REPO="file://$remote" \
  CHECKOUT_DIR="$base/checkout" \
  CLAUDE_BIN="$stub/claude" \
  STATE_FILE="$base/state" \
  WORK_SLEEP=3 IDLE_SLEEP=60 \
  MAX_ITERATIONS=1 \
  PATH="$stub:$PATH" \
    bash "$LOOP" >/dev/null 2>"$base/stderr.log"

  local first; first="$(head -n1 "$RUN_LOG")"
  [[ "$first" == "-p /implement 01-wip-1 --dangerously-skip-permissions"* ]] \
    && ok "lowest NN- in-progress story (01-wip-1) is resumed first" \
    || nope "expected resume of 01-wip-1, got: [$first]"
}

# Count tracked rows on the remote's user-verification (quarantine) column.
count_remote_verification() {
  local remote="$1"
  git --git-dir="$remote" ls-tree -r --name-only main \
    | grep -c '^kanban-board/04-user-verification/.*/' || true
}

# Stub dir with a "poison-pill" claude that always crashes: it records the
# invocation and exits non-zero without touching the board, so the resumed story
# stays stranded in `03-in-progress/` — the signal the retry cap consumes. Pairs
# with the recording `sleep`. Echoes the stub dir.
make_poison_stubs() {
  local base="$1"
  local stub="$base/stub"
  mkdir -p "$stub"

  cat > "$stub/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RUN_LOG"
exit 1
EOF
  chmod +x "$stub/claude"

  cat > "$stub/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$SLEEP_LOG"
EOF
  chmod +x "$stub/sleep"

  printf '%s' "$stub"
}

# --- Test: a poison-pill story is quarantined after MAX_RETRIES failed resumes -
#
# Slice 06: a story stranded in `03-in-progress/` whose `/implement` keeps
# crashing must not be resumed forever. After MAX_RETRIES consecutive failed
# resumes the loop parks it to `04-user-verification/` with a "crashed N×" note,
# clears it from in-progress, and proceeds to drain `02-refined/`.

test_quarantine_after_retry_cap() {
  local base; base="$(mktemp -d)"
  trap 'rm -rf "$base"' RETURN

  # 1 refined story to drain afterwards, plus 1 stranded poison story.
  local remote; remote="$(make_fixture_remote "$base" 1 1)"
  local stub;   stub="$(make_poison_stubs "$base")"
  export RUN_LOG="$base/run.log"; : > "$RUN_LOG"
  export SLEEP_LOG="$base/sleep.log"; : > "$SLEEP_LOG"

  # 3 failed resumes -> quarantine on the 3rd; a 4th iteration then drains refined.
  TARGET_REPO="file://$remote" \
  CHECKOUT_DIR="$base/checkout" \
  CLAUDE_BIN="$stub/claude" \
  STATE_FILE="$base/state" \
  MAX_RETRIES=3 \
  WORK_SLEEP=3 IDLE_SLEEP=60 \
  MAX_ITERATIONS=4 \
  PATH="$stub:$PATH" \
    bash "$LOOP" >/dev/null 2>"$base/stderr.log"
  local rc=$?

  [ "$rc" -eq 0 ] && ok "loop exits 0 across quarantine" || nope "expected exit 0, got $rc"

  # The poison story was resumed exactly MAX_RETRIES times before being parked.
  local resumes; resumes="$(grep -c -- '/implement 01-wip-1 ' "$RUN_LOG")"
  [ "$resumes" -eq 3 ] \
    && ok "poison story resumed exactly MAX_RETRIES (3) times, then quarantined" \
    || nope "expected 3 resumes before quarantine, got $resumes"

  # It is cleared from in-progress and lands in the verification column...
  local wip; wip="$(count_remote_in_progress "$remote")"
  [ "$wip" -eq 0 ] \
    && ok "quarantined story is cleared from in-progress on the remote" \
    || nope "expected 0 in-progress stories left, got $wip"

  local verif; verif="$(count_remote_verification "$remote")"
  [ "$verif" -ge 1 ] \
    && ok "quarantined story is parked to 04-user-verification on the remote" \
    || nope "expected story in 04-user-verification, got $verif rows"

  # ...with a crashed-N× note.
  if git --git-dir="$remote" show "main:kanban-board/04-user-verification/01-wip-1/QUARANTINE.md" 2>/dev/null \
       | grep -q 'crashed 3 times'; then
    ok "quarantine note records the crash count (3 times)"
  else
    nope "quarantine note missing or wrong crash count"
  fi

  # After quarantine the loop proceeds to drain refined: the 4th iteration uses
  # the no-slug form (and crashes harmlessly, leaving the refined story in place).
  local fourth; fourth="$(sed -n '4p' "$RUN_LOG")"
  [[ "$fourth" == "-p /implement --dangerously-skip-permissions"* ]] \
    && ok "loop proceeds to drain 02-refined after quarantine (no-slug form)" \
    || nope "expected no-slug drain on 4th iteration, got: [$fourth]"

  # The counter was reset on quarantine (no lingering row for the parked slug).
  if [ ! -s "$base/state" ] || ! grep -q '01-wip-1' "$base/state"; then
    ok "failure counter is reset after quarantine"
  else
    nope "failure counter still records the quarantined slug"
  fi
}

# --- Test: the failure counter survives a process restart ---------------------
#
# The count lives in a volume-persisted state file, not in memory, so a crash/
# restart of the loop process must not reset a poison story's progress toward the
# cap. Two failed resumes in one process, then a third in a *fresh* process, must
# still trigger quarantine — proving the count was read back from disk.

test_counter_survives_restart() {
  local base; base="$(mktemp -d)"
  trap 'rm -rf "$base"' RETURN

  local remote; remote="$(make_fixture_remote "$base" 0 1)"
  local stub;   stub="$(make_poison_stubs "$base")"
  export RUN_LOG="$base/run.log"; : > "$RUN_LOG"
  export SLEEP_LOG="$base/sleep.log"; : > "$SLEEP_LOG"

  local env_common=(
    "TARGET_REPO=file://$remote"
    "CHECKOUT_DIR=$base/checkout"
    "CLAUDE_BIN=$stub/claude"
    "STATE_FILE=$base/state"
    "MAX_RETRIES=3"
    "WORK_SLEEP=3" "IDLE_SLEEP=60"
    "PATH=$stub:$PATH"
  )

  # Process #1: two failed resumes — count reaches 2, below the cap.
  env "${env_common[@]}" MAX_ITERATIONS=2 \
    bash "$LOOP" >/dev/null 2>"$base/stderr1.log"

  local wip1; wip1="$(count_remote_in_progress "$remote")"
  [ "$wip1" -eq 1 ] \
    && ok "story still in progress after 2 failures (below cap)" \
    || nope "expected story still in progress, got $wip1 rows"

  local persisted; persisted="$(awk -F'\t' '$1=="01-wip-1"{print $2}' "$base/state")"
  [ "$persisted" = "2" ] \
    && ok "failure count (2) is persisted to the state file" \
    || nope "expected persisted count 2, got: [$persisted]"

  # Process #2: a single further failed resume tips it over the cap. This only
  # quarantines if the count was read back from disk (2 -> 3); a reset-on-restart
  # bug would leave it at 1 and never park.
  env "${env_common[@]}" MAX_ITERATIONS=1 \
    bash "$LOOP" >/dev/null 2>"$base/stderr2.log"

  local wip2; wip2="$(count_remote_in_progress "$remote")"
  local verif; verif="$(count_remote_verification "$remote")"
  if [ "$wip2" -eq 0 ] && [ "$verif" -ge 1 ]; then
    ok "one more failure after restart quarantines (count survived the restart)"
  else
    nope "expected quarantine after restart (in-progress=$wip2, verification=$verif)"
  fi
}

echo "test_drain_then_idle";          test_drain_then_idle
echo "test_idle_no_work";             test_idle_no_work
echo "test_resume_before_drain";      test_resume_before_drain
echo "test_resume_lowest_in_progress"; test_resume_lowest_in_progress
echo "test_quarantine_after_retry_cap"; test_quarantine_after_retry_cap
echo "test_counter_survives_restart";  test_counter_survives_restart
echo "test_timeout_continues_loop";   test_timeout_continues_loop
echo "test_progress_narrates_story_outcome"; test_progress_narrates_story_outcome
echo "test_progress_incomplete_when_nothing_lands"; test_progress_incomplete_when_nothing_lands
echo "test_requires_repo";            test_requires_repo

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
