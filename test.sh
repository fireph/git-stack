#!/usr/bin/env bash
# Self-contained tests for git-stack.
# Creates throwaway git repos in a temp dir; no `gh` required.
# Exits non-zero if any test fails.

set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/git-stack"
TMP="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# mkrepo <name> : create $TMP/<name> with a 3-branch stack p1->p2->p3 on main
mkrepo() {
  local d="$TMP/$1"
  rm -rf "$d" && mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  git -C "$d" commit -q --allow-empty -m base
  git -C "$d" checkout -q -b p1; git -C "$d" commit -q --allow-empty -m "part 1"
  git -C "$d" checkout -q -b p2; git -C "$d" commit -q --allow-empty -m "part 2"
  git -C "$d" checkout -q -b p3; git -C "$d" commit -q --allow-empty -m "part 3"
}

# chain_ok <dir> : return 0 if p1 on main, p2 on p1, p3 on p2
chain_ok() {
  local d="$1"
  [ "$(git -C "$d" rev-parse p1^)" = "$(git -C "$d" rev-parse main)" ] || { echo "  p1 not on main" >&2; return 1; }
  [ "$(git -C "$d" rev-parse p2^)" = "$(git -C "$d" rev-parse p1)"  ] || { echo "  p2 not on p1" >&2; return 1; }
  [ "$(git -C "$d" rev-parse p3^)" = "$(git -C "$d" rev-parse p2)"  ] || { echo "  p3 not on p2" >&2; return 1; }
  return 0
}

# gs <dir> <args...> : run git-stack with cwd = dir
gs() {
  local d="$1"; shift
  (cd "$d" && python3 "$SCRIPT" "$@")
}

# run_test <name> <fn> : run fn, record pass/fail
run_test() {
  local name="$1"; shift
  if "$@"; then
    echo "ok   - $name"
    PASS=$((PASS+1))
  else
    echo "FAIL - $name"
    FAIL=$((FAIL+1))
  fi
}

# --- tests (each returns 0 on success, 1 on failure) ---

t_list_shows_full_stack_from_each_branch() {
  mkrepo r; local d="$TMP/r"
  for b in p1 p2 p3; do
    git -C "$d" checkout -q "$b"
    local out; out=$(gs "$d" list 2>/dev/null)
    echo "$out" | grep -q "p1 ←" || return 1
    echo "$out" | grep -q "p2 ←" || return 1
    echo "$out" | grep -q "p3 ←" || return 1
  done
  return 0
}

t_restack_bottom_from_each_branch() {
  for b in p1 p2 p3; do
    mkrepo r; local d="$TMP/r"
    git -C "$d" checkout -q p1
    git -C "$d" commit -q --amend --no-edit --allow-empty -m "part 1 amended"
    git -C "$d" checkout -q "$b"
    gs "$d" restack >/dev/null 2>&1 || return 1
    chain_ok "$d" || return 1
  done
  return 0
}

t_restack_middle_from_each_branch() {
  for b in p1 p2 p3; do
    mkrepo r; local d="$TMP/r"
    git -C "$d" checkout -q p2
    git -C "$d" commit -q --amend --no-edit --allow-empty -m "part 2 amended"
    git -C "$d" checkout -q "$b"
    gs "$d" restack >/dev/null 2>&1 || return 1
    chain_ok "$d" || return 1
  done
  return 0
}

t_restack_top_already_restacked() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q p3
  git -C "$d" commit -q --amend --no-edit --allow-empty -m "part 3 amended"
  git -C "$d" checkout -q p1
  local out; out=$(gs "$d" restack 2>/dev/null)
  echo "$out" | grep -q "already restacked" || return 1
  chain_ok "$d" || return 1
  return 0
}

t_restack_no_amend_already_restacked() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q p2
  local out; out=$(gs "$d" restack 2>/dev/null)
  echo "$out" | grep -q "already restacked" || return 1
  return 0
}

t_status_behind_main_shows_needs_rebase() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q main
  git -C "$d" commit -q --allow-empty -m "main moved"
  git -C "$d" checkout -q p2
  local out; out=$(gs "$d" status main 2>/dev/null)
  echo "$out" | grep -q "p1 ←.*needs rebase" || return 1
  echo "$out" | grep -q "p2 ←.*ok" || return 1
  echo "$out" | grep -q "p3 ←.*ok" || return 1
  echo "$out" | grep -q "git stack rebase" || return 1
  return 0
}

t_amend_and_behind_main_restack_then_still_rebase() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q main
  git -C "$d" commit -q --allow-empty -m "main moved"
  git -C "$d" checkout -q p1
  git -C "$d" commit -q --amend --no-edit --allow-empty -m "part 1 amended"
  git -C "$d" checkout -q p3
  gs "$d" restack >/dev/null 2>&1 || return 1
  # inter-stack chain intact after restack
  [ "$(git -C "$d" rev-parse p2^)" = "$(git -C "$d" rev-parse p1)" ] || return 1
  [ "$(git -C "$d" rev-parse p3^)" = "$(git -C "$d" rev-parse p2)" ] || return 1
  # status still says rebase (p1 behind main), not restack
  local out; out=$(gs "$d" status main 2>/dev/null)
  echo "$out" | grep -q "p1 ←.*needs rebase" || return 1
  echo "$out" | grep -q "p2 ←.*ok" || return 1
  echo "$out" | grep -q "p3 ←.*ok" || return 1
  return 0
}

t_amend_middle_status_shows_needs_restack() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q p2
  git -C "$d" commit -q --amend --no-edit --allow-empty -m "part 2 amended"
  git -C "$d" checkout -q p1
  local out; out=$(gs "$d" status main 2>/dev/null)
  echo "$out" | grep -q "p1 ←.*ok" || return 1
  echo "$out" | grep -q "p2 ←.*ok" || return 1
  echo "$out" | grep -q "p3 ←.*needs restack" || return 1
  echo "$out" | grep -q "git stack restack" || return 1
  return 0
}

# --- rebase command ---

t_rebase_onto_moved_main_preserves_chain() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q main
  git -C "$d" commit -q --allow-empty -m "main moved"
  git -C "$d" checkout -q p2
  gs "$d" rebase main >/dev/null 2>&1 || return 1
  chain_ok "$d" || return 1
  # subjects preserved through the rebase
  [ "$(git -C "$d" log -1 --format=%s p1)" = "part 1" ] || return 1
  [ "$(git -C "$d" log -1 --format=%s p2)" = "part 2" ] || return 1
  [ "$(git -C "$d" log -1 --format=%s p3)" = "part 3" ] || return 1
  return 0
}

t_rebase_then_status_all_ok() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q main
  git -C "$d" commit -q --allow-empty -m "main moved"
  git -C "$d" checkout -q p2
  gs "$d" rebase main >/dev/null 2>&1 || return 1
  local out; out=$(gs "$d" status main 2>/dev/null)
  echo "$out" | grep -q "p1 ←.*ok" || return 1
  echo "$out" | grep -q "p2 ←.*ok" || return 1
  echo "$out" | grep -q "p3 ←.*ok" || return 1
  echo "$out" | grep -q "all branches restacked cleanly" || return 1
  return 0
}

t_rebase_single_branch_prints_hint() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q p1
  # remove p2,p3 so only p1 remains in the stack
  git -C "$d" branch -qD p2 p3
  local out; out=$(gs "$d" rebase main 2>/dev/null)
  echo "$out" | grep -q "only one branch" || return 1
  return 0
}

# --- single-branch stack ---

t_restack_single_branch_says_nothing_to_restack() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q p1
  git -C "$d" branch -qD p2 p3
  local out; out=$(gs "$d" restack 2>/dev/null)
  echo "$out" | grep -q "only branch in the stack" || return 1
  return 0
}

# --- two-branch stack (minimum non-trivial) ---

t_restack_two_branch_after_amend_bottom() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q p1
  git -C "$d" branch -qD p3
  git -C "$d" commit -q --amend --no-edit --allow-empty -m "part 1 amended"
  git -C "$d" checkout -q p2
  gs "$d" restack >/dev/null 2>&1 || return 1
  [ "$(git -C "$d" rev-parse p1^)" = "$(git -C "$d" rev-parse main)" ] || return 1
  [ "$(git -C "$d" rev-parse p2^)" = "$(git -C "$d" rev-parse p1)"  ] || return 1
  return 0
}

t_status_two_branch_after_amend_shows_needs_restack() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q p1
  git -C "$d" branch -qD p3
  git -C "$d" commit -q --amend --no-edit --allow-empty -m "part 1 amended"
  git -C "$d" checkout -q p2
  local out; out=$(gs "$d" status main 2>/dev/null)
  echo "$out" | grep -q "p1 ←.*ok" || return 1
  echo "$out" | grep -q "p2 ←.*needs restack" || return 1
  return 0
}

# --- restack returns to original branch ---

t_restack_returns_to_original_branch() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q p1
  git -C "$d" commit -q --amend --no-edit --allow-empty -m "part 1 amended"
  for b in p1 p2 p3; do
    git -C "$d" checkout -q "$b"
    gs "$d" restack >/dev/null 2>&1 || return 1
    [ "$(git -C "$d" rev-parse --abbrev-ref HEAD)" = "$b" ] || return 1
  done
  return 0
}

# --- unrelated sibling branch excluded from detection ---

t_unrelated_sibling_excluded_from_stack() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q main
  git -C "$d" checkout -q -b unrelated
  git -C "$d" commit -q --allow-empty -m "other work"
  git -C "$d" checkout -q p2
  local out; out=$(gs "$d" list 2>/dev/null)
  echo "$out" | grep -q "p1" || return 1
  echo "$out" | grep -q "p2" || return 1
  if echo "$out" | grep -q "unrelated"; then return 1; fi
  return 0
}

# --- multiple amends before a single restack ---

t_restack_multiple_amends_preserves_all() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q p1
  git -C "$d" commit -q --amend --no-edit --allow-empty -m "part 1 amended"
  git -C "$d" checkout -q p2
  git -C "$d" commit -q --amend --no-edit --allow-empty -m "part 2 amended"
  git -C "$d" checkout -q p3
  gs "$d" restack >/dev/null 2>&1 || return 1
  chain_ok "$d" || return 1
  [ "$(git -C "$d" log -1 --format=%s p1)" = "part 1 amended" ] || return 1
  [ "$(git -C "$d" log -1 --format=%s p2)" = "part 2 amended" ] || return 1
  [ "$(git -C "$d" log -1 --format=%s p3)" = "part 3" ] || return 1
  return 0
}

# --- detached HEAD errors ---

t_detached_head_errors() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q "$(git -C "$d" rev-parse p2)"
  local out; out=$(gs "$d" list 2>&1) || true
  echo "$out" | grep -qi "detached HEAD" || return 1
  return 0
}

# --- run all tests ---

run_test "list shows full stack from each branch"              t_list_shows_full_stack_from_each_branch
run_test "restack after amending bottom works from any branch" t_restack_bottom_from_each_branch
run_test "restack after amending middle works from any branch" t_restack_middle_from_each_branch
run_test "restack after amending top says already restacked"   t_restack_top_already_restacked
run_test "restack with no amend says already restacked"        t_restack_no_amend_already_restacked
run_test "status behind main shows needs rebase on bottom"     t_status_behind_main_shows_needs_rebase
run_test "amend+behind main: restack fixes stack, still rebase" t_amend_and_behind_main_restack_then_still_rebase
run_test "amend middle: status shows needs restack above"      t_amend_middle_status_shows_needs_restack
run_test "rebase onto moved main preserves chain + subjects"  t_rebase_onto_moved_main_preserves_chain
run_test "rebase then status shows all ok"                     t_rebase_then_status_all_ok
run_test "rebase with single branch prints hint"               t_rebase_single_branch_prints_hint
run_test "restack single branch says nothing to restack"      t_restack_single_branch_says_nothing_to_restack
run_test "two-branch: restack after amending bottom"          t_restack_two_branch_after_amend_bottom
run_test "two-branch: status shows needs restack after amend"  t_status_two_branch_after_amend_shows_needs_restack
run_test "restack returns to the branch you were on"          t_restack_returns_to_original_branch
run_test "unrelated sibling branch excluded from stack"       t_unrelated_sibling_excluded_from_stack
run_test "restack with multiple amends preserves all"         t_restack_multiple_amends_preserves_all
run_test "detached HEAD errors cleanly"                        t_detached_head_errors

echo
echo "$PASS passed, $FAIL failed"

[ "$FAIL" -eq 0 ]
