#!/usr/bin/env bash
#
# Tests for setup/init-target.sh — the target-repo onboarding scaffolder.
#
# No bats dependency: a self-contained bash harness. Each test builds a fixture
# target repo (a real git working copy) and runs the scaffolder with autofill OFF
# (AUTOFILL=0) so the deterministic file-scaffold path is exercised without
# needing a Claude CLI. We assert on the files it installs into the target.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT="$ROOT/setup/init-target.sh"

PASS=0
FAIL=0

ok()   { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
nope() { printf '  FAIL - %s\n' "$1"; FAIL=$((FAIL + 1)); }

# A minimal git working copy standing in for a target repo. Echoes its path.
make_target_repo() {
  local base="$1"
  local repo="$base/target"
  git init --quiet "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name "Test"
  printf '# Target\n\nExisting project guidance.\n' > "$repo/CLAUDE.md"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m "seed: target repo"
  printf '%s' "$repo"
}

# --- Test: fresh scaffold ----------------------------------------------------

test_scaffolds_a_fresh_repo() {
  local base; base="$(mktemp -d)"
  trap 'rm -rf "$base"' RETURN
  local repo; repo="$(make_target_repo "$base")"

  AUTOFILL=0 bash "$INIT" "$repo" >/dev/null 2>"$base/err.log"
  local rc=$?

  [ "$rc" -eq 0 ] && ok "exits 0 on a fresh scaffold" || nope "expected exit 0, got $rc"

  [ -f "$repo/.claude/skills/implement/SKILL.md" ] \
    && ok "installs the implement skill" || nope "missing implement skill"
  [ -f "$repo/.claude/agents/slice-lander.md" ] \
    && ok "installs the slice-lander agent" || nope "missing slice-lander agent"

  local col missing=0
  for col in 01-backlog 02-refined 03-in-progress 04-user-verification; do
    [ -f "$repo/kanban-board/$col/.gitkeep" ] || missing=1
  done
  [ "$missing" -eq 0 ] && ok "creates all four board columns with .gitkeep" \
    || nope "did not create the full board skeleton"

  grep -q 'coder:process-kit' "$repo/CLAUDE.md" \
    && ok "appends the loop section to CLAUDE.md" || nope "did not append loop section"
  grep -q 'Existing project guidance' "$repo/CLAUDE.md" \
    && ok "preserves the repo's existing CLAUDE.md" || nope "clobbered existing CLAUDE.md"

  # The repo-specific blanks must survive as TODOs when autofill is off.
  grep -q 'TODO(coder)' "$repo/.claude/agents/slice-lander.md" \
    && ok "leaves slice-lander TODO blanks when autofill is off" \
    || nope "slice-lander blanks unexpectedly filled/removed"
}

# --- Test: no clobber without --force ----------------------------------------

test_does_not_clobber_without_force() {
  local base; base="$(mktemp -d)"
  trap 'rm -rf "$base"' RETURN
  local repo; repo="$(make_target_repo "$base")"

  mkdir -p "$repo/.claude/agents"
  printf 'MY OWN LANDER\n' > "$repo/.claude/agents/slice-lander.md"

  AUTOFILL=0 bash "$INIT" "$repo" >/dev/null 2>"$base/err.log"

  grep -qx 'MY OWN LANDER' "$repo/.claude/agents/slice-lander.md" \
    && ok "leaves an existing slice-lander untouched without --force" \
    || nope "clobbered an existing slice-lander without --force"

  AUTOFILL=0 bash "$INIT" "$repo" --force >/dev/null 2>"$base/err.log"
  grep -q 'Slice Lander' "$repo/.claude/agents/slice-lander.md" \
    && ok "overwrites with --force" || nope "--force did not overwrite"
}

# --- Test: idempotent CLAUDE.md merge ----------------------------------------

test_claude_merge_is_idempotent() {
  local base; base="$(mktemp -d)"
  trap 'rm -rf "$base"' RETURN
  local repo; repo="$(make_target_repo "$base")"

  AUTOFILL=0 bash "$INIT" "$repo" >/dev/null 2>"$base/err.log"
  AUTOFILL=0 bash "$INIT" "$repo" >/dev/null 2>"$base/err.log"

  local n; n="$(grep -c 'coder:process-kit' "$repo/CLAUDE.md")"
  [ "$n" -eq 1 ] && ok "appends the loop section at most once" \
    || nope "loop section appended $n times (expected 1)"
}

# --- Test: requires a git target ---------------------------------------------

test_requires_git_repo() {
  local base; base="$(mktemp -d)"
  trap 'rm -rf "$base"' RETURN
  mkdir -p "$base/not-a-repo"

  AUTOFILL=0 bash "$INIT" "$base/not-a-repo" >/dev/null 2>"$base/err.log"
  local rc=$?
  [ "$rc" -eq 2 ] && ok "fails on a non-git target" \
    || nope "expected exit 2 for non-git target, got $rc"

  AUTOFILL=0 bash "$INIT" >/dev/null 2>"$base/err.log"
  rc=$?
  [ "$rc" -eq 2 ] && ok "fails when no target path is given" \
    || nope "expected exit 2 for missing target, got $rc"
}

echo "test_scaffolds_a_fresh_repo";       test_scaffolds_a_fresh_repo
echo "test_does_not_clobber_without_force"; test_does_not_clobber_without_force
echo "test_claude_merge_is_idempotent";    test_claude_merge_is_idempotent
echo "test_requires_git_repo";             test_requires_git_repo

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
