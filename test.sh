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

# mkrepo_multi <name> : create a 3-branch stack with two real commits per branch
mkrepo_multi() {
  local d="$TMP/$1"
  rm -rf "$d" && mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  git -C "$d" commit -q --allow-empty -m base
  for b in p1 p2 p3; do
    git -C "$d" checkout -q -b "$b"
    git -C "$d" commit -q --allow-empty -m "$b first"
    printf '%s second\n' "$b" > "$d/$b-second.txt"
    git -C "$d" add "$b-second.txt"
    git -C "$d" commit -q -m "$b second"
  done
}

# rewrite_first_owned_commit <dir> <branch> <parent>
# Replaces the first commit in a branch's two-commit range, then replays the
# second. This is equivalent to amending a non-tip commit with interactive rebase.
rewrite_first_owned_commit() {
  local d="$1" branch="$2" parent="$3"
  local old_tip first
  old_tip=$(git -C "$d" rev-parse "$branch")
  first=$(git -C "$d" rev-list --reverse "$parent..$branch" | sed -n '1p')
  git -C "$d" checkout -q -b rewrite-interior "$parent"
  git -C "$d" commit -q --allow-empty -m "$branch first amended"
  git -C "$d" cherry-pick "$first..$old_tip" >/dev/null || return 1
  git -C "$d" branch -qf "$branch" HEAD
  git -C "$d" checkout -q "$branch"
  git -C "$d" branch -qD rewrite-interior
}

# chain_ok <dir> : return 0 if p1 on main, p2 on p1, p3 on p2
chain_ok() {
  local d="$1"
  [ "$(git -C "$d" rev-parse p1^)" = "$(git -C "$d" rev-parse main)" ] || { echo "  p1 not on main" >&2; return 1; }
  [ "$(git -C "$d" rev-parse p2^)" = "$(git -C "$d" rev-parse p1)"  ] || { echo "  p2 not on p1" >&2; return 1; }
  [ "$(git -C "$d" rev-parse p3^)" = "$(git -C "$d" rev-parse p2)"  ] || { echo "  p3 not on p2" >&2; return 1; }
  return 0
}

# range_count <dir> <parent> <child> <expected>
range_count() {
  [ "$(git -C "$1" rev-list --count "$2..$3")" = "$4" ]
}

# multi_chain_ok <dir> <p1-count> <p2-count> <p3-count>
multi_chain_ok() {
  range_count "$1" main p1 "$2" || return 1
  range_count "$1" p1 p2 "$3" || return 1
  range_count "$1" p2 p3 "$4" || return 1
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

t_rebase_multicommit_preserves_branch_ranges() {
  mkrepo r; local d="$TMP/r"
  for b in p1 p2 p3; do
    git -C "$d" checkout -q "$b"
    git -C "$d" commit -q --allow-empty -m "$b extra"
  done
  git -C "$d" checkout -q main
  git -C "$d" commit -q --allow-empty -m "main moved"
  git -C "$d" checkout -q p2
  gs "$d" rebase main >/dev/null 2>&1 || return 1
  range_count "$d" main p1 2 || return 1
  range_count "$d" p1 p2 2 || return 1
  range_count "$d" p2 p3 2 || return 1
}

t_rebase_single_branch_rebases() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q p1
  # remove p2,p3 so only p1 remains in the stack
  git -C "$d" branch -qD p2 p3
  git -C "$d" checkout -q main
  git -C "$d" commit -q --allow-empty -m "main moved"
  git -C "$d" checkout -q p1
  gs "$d" rebase main >/dev/null 2>&1 || return 1
  [ "$(git -C "$d" rev-parse p1^)" = "$(git -C "$d" rev-parse main)" ] || return 1
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

# --- multiple commits per branch ---

t_multicommit_detection_from_each_branch() {
  mkrepo r; local d="$TMP/r"
  for b in p1 p2 p3; do
    git -C "$d" checkout -q "$b"
    git -C "$d" commit -q --allow-empty -m "$b second"
  done
  for b in p1 p2 p3; do
    git -C "$d" checkout -q "$b"
    local out; out=$(gs "$d" list 2>/dev/null)
    echo "$out" | grep -q "p1 ←" || return 1
    echo "$out" | grep -q "p2 ← p1" || return 1
    echo "$out" | grep -q "p3 ← p2" || return 1
  done
}

t_restack_after_adds_preserves_branch_ranges() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q p1
  git -C "$d" commit -q --allow-empty -m "part 1 extra"
  git -C "$d" checkout -q p2
  git -C "$d" commit -q --allow-empty -m "part 2 extra"
  git -C "$d" checkout -q p3
  gs "$d" restack >/dev/null 2>&1 || return 1
  range_count "$d" main p1 2 || return 1
  range_count "$d" p1 p2 2 || return 1
  range_count "$d" p2 p3 1 || return 1
  [ "$(git -C "$d" log -1 --format=%s p1)" = "part 1 extra" ] || return 1
  [ "$(git -C "$d" log -1 --format=%s p2)" = "part 2 extra" ] || return 1
}

t_restack_after_multicommit_amend_preserves_range() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q p2
  git -C "$d" commit -q --allow-empty -m "part 2 extra"
  git -C "$d" commit -q --amend --allow-empty -m "part 2 extra amended"
  git -C "$d" checkout -q p1
  gs "$d" restack >/dev/null 2>&1 || return 1
  range_count "$d" p1 p2 2 || return 1
  range_count "$d" p2 p3 1 || return 1
  [ "$(git -C "$d" log -1 --format=%s p2)" = "part 2 extra amended" ] || return 1
  [ "$(git -C "$d" log -1 --format=%s p3)" = "part 3" ] || return 1
}

t_status_after_parent_append_requires_restack() {
  mkrepo_multi r; local d="$TMP/r"
  git -C "$d" checkout -q p2
  git -C "$d" commit -q --allow-empty -m "p2 third"
  git -C "$d" checkout -q p1
  local out; out=$(gs "$d" status main 2>/dev/null)
  echo "$out" | grep -q "p2 ←.*ok" || return 1
  echo "$out" | grep -q "p3 ←.*needs restack" || return 1
}

t_top_append_needs_no_restack() {
  mkrepo_multi r; local d="$TMP/r"
  git -C "$d" checkout -q p3
  git -C "$d" commit -q --allow-empty -m "p3 third"
  local out; out=$(gs "$d" restack 2>/dev/null)
  echo "$out" | grep -q "already restacked" || return 1
  range_count "$d" p2 p3 3 || return 1
}

t_restack_interior_amend_middle_branch() {
  mkrepo_multi r; local d="$TMP/r"
  rewrite_first_owned_commit "$d" p2 p1 || return 1
  git -C "$d" checkout -q p3
  gs "$d" restack >/dev/null 2>&1 || return 1
  range_count "$d" main p1 2 || return 1
  range_count "$d" p1 p2 2 || return 1
  range_count "$d" p2 p3 2 || return 1
  [ "$(git -C "$d" log --reverse --format=%s p1..p2 | sed -n '1p')" = "p2 first amended" ] || return 1
  [ "$(git -C "$d" log -1 --format=%s p2)" = "p2 second" ] || return 1
}

t_restack_interior_amend_bottom_from_each_branch() {
  for current in p1 p2 p3; do
    mkrepo_multi r; local d="$TMP/r"
    rewrite_first_owned_commit "$d" p1 main || return 1
    git -C "$d" checkout -q "$current"
    gs "$d" restack >/dev/null 2>&1 || return 1
    range_count "$d" main p1 2 || return 1
    range_count "$d" p1 p2 2 || return 1
    range_count "$d" p2 p3 2 || return 1
    [ "$(git -C "$d" log --reverse --format=%s main..p1 | sed -n '1p')" = "p1 first amended" ] || return 1
  done
}

t_restack_mixed_appends_and_interior_amends() {
  mkrepo_multi r; local d="$TMP/r"
  rewrite_first_owned_commit "$d" p1 main || return 1
  git -C "$d" checkout -q p2
  git -C "$d" commit -q --allow-empty -m "p2 third"
  git -C "$d" checkout -q p3
  git -C "$d" commit -q --allow-empty -m "p3 third"
  gs "$d" restack >/dev/null 2>&1 || return 1
  range_count "$d" main p1 2 || return 1
  range_count "$d" p1 p2 3 || return 1
  range_count "$d" p2 p3 3 || return 1
  [ "$(git -C "$d" log -1 --format=%s p2)" = "p2 third" ] || return 1
  [ "$(git -C "$d" log -1 --format=%s p3)" = "p3 third" ] || return 1
}

t_restack_multicommit_is_idempotent() {
  mkrepo_multi r; local d="$TMP/r"
  git -C "$d" checkout -q p1
  git -C "$d" commit -q --allow-empty -m "p1 third"
  git -C "$d" checkout -q p2
  gs "$d" restack >/dev/null 2>&1 || return 1
  local p1_before p2_before p3_before out
  p1_before=$(git -C "$d" rev-parse p1)
  p2_before=$(git -C "$d" rev-parse p2)
  p3_before=$(git -C "$d" rev-parse p3)
  out=$(gs "$d" restack 2>/dev/null)
  echo "$out" | grep -q "already restacked" || return 1
  [ "$p1_before" = "$(git -C "$d" rev-parse p1)" ] || return 1
  [ "$p2_before" = "$(git -C "$d" rev-parse p2)" ] || return 1
  [ "$p3_before" = "$(git -C "$d" rev-parse p3)" ] || return 1
}

# Primary workflows: amend or append at a branch tip with descendants above it.

t_tip_amend_multicommit_parent_from_every_branch() {
  local changed parent current
  for changed in p1 p2; do
    [ "$changed" = p1 ] && parent=main || parent=p1
    for current in p1 p2 p3; do
      mkrepo_multi r; local d="$TMP/r"
      git -C "$d" checkout -q "$changed"
      printf '%s amended\n' "$changed" >> "$d/$changed-second.txt"
      git -C "$d" add "$changed-second.txt"
      git -C "$d" commit -q --amend --no-edit

      # Detection must retain the complete stack before it is repaired.
      git -C "$d" checkout -q "$current"
      local listed; listed=$(gs "$d" list 2>/dev/null)
      echo "$listed" | grep -q "p1 ←" || return 1
      echo "$listed" | grep -q "p2 ← p1" || return 1
      echo "$listed" | grep -q "p3 ← p2" || return 1

      gs "$d" restack >/dev/null 2>&1 || return 1
      multi_chain_ok "$d" 2 2 2 || return 1
      git -C "$d" show "$changed:$changed-second.txt" | grep -q "$changed amended" || return 1
      [ "$(git -C "$d" rev-parse --abbrev-ref HEAD)" = "$current" ] || return 1
    done
  done
}

t_tip_append_multicommit_parent_from_every_branch() {
  local changed current expected_p1 expected_p2
  for changed in p1 p2; do
    for current in p1 p2 p3; do
      mkrepo_multi r; local d="$TMP/r"
      git -C "$d" checkout -q "$changed"
      printf '%s third\n' "$changed" > "$d/$changed-third.txt"
      git -C "$d" add "$changed-third.txt"
      git -C "$d" commit -q -m "$changed third"

      git -C "$d" checkout -q "$current"
      local status; status=$(gs "$d" status main 2>/dev/null)
      if [ "$changed" = p1 ]; then
        echo "$status" | grep -q "p2 ←.*needs restack" || return 1
        expected_p1=3; expected_p2=2
      else
        echo "$status" | grep -q "p3 ←.*needs restack" || return 1
        expected_p1=2; expected_p2=3
      fi

      gs "$d" restack >/dev/null 2>&1 || return 1
      multi_chain_ok "$d" "$expected_p1" "$expected_p2" 2 || return 1
      [ "$(git -C "$d" show "$changed:$changed-third.txt")" = "$changed third" ] || return 1
      [ "$(git -C "$d" rev-parse --abbrev-ref HEAD)" = "$current" ] || return 1
    done
  done
}

t_tip_amend_then_append_same_middle_branch() {
  mkrepo_multi r; local d="$TMP/r"
  git -C "$d" checkout -q p2
  printf 'p2 amended\n' >> "$d/p2-second.txt"
  git -C "$d" add p2-second.txt
  git -C "$d" commit -q --amend --no-edit
  printf 'p2 third\n' > "$d/p2-third.txt"
  git -C "$d" add p2-third.txt
  git -C "$d" commit -q -m "p2 third"
  git -C "$d" checkout -q p1
  gs "$d" restack >/dev/null 2>&1 || return 1
  multi_chain_ok "$d" 2 3 2 || return 1
  git -C "$d" show p2:p2-second.txt | grep -q "p2 amended" || return 1
  [ "$(git -C "$d" show p2:p2-third.txt)" = "p2 third" ] || return 1
}

t_tip_changes_on_multiple_levels_single_restack() {
  mkrepo_multi r; local d="$TMP/r"
  git -C "$d" checkout -q p1
  printf 'p1 amended\n' >> "$d/p1-second.txt"
  git -C "$d" add p1-second.txt
  git -C "$d" commit -q --amend --no-edit
  git -C "$d" checkout -q p2
  printf 'p2 third\n' > "$d/p2-third.txt"
  git -C "$d" add p2-third.txt
  git -C "$d" commit -q -m "p2 third"
  git -C "$d" checkout -q p3
  gs "$d" restack >/dev/null 2>&1 || return 1
  multi_chain_ok "$d" 2 3 2 || return 1
  grep -q "p1 amended" "$d/p1-second.txt" || return 1
  [ "$(git -C "$d" show p2:p2-third.txt)" = "p2 third" ] || return 1
  [ "$(git -C "$d" log -1 --format=%s p3)" = "p3 second" ] || return 1
}

# --- safety, ambiguity, and failure paths ---

t_shell_metacharacters_in_branch_are_safe() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q main
  git -C "$d" checkout -q -b 'evil;false'
  git -C "$d" commit -q --allow-empty -m evil
  local out; out=$(gs "$d" list 2>/dev/null) || return 1
  echo "$out" | grep -q 'evil;false' || return 1
}

t_restack_uses_boundary_beyond_fifty_reflog_entries() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q p1
  local i
  for i in $(seq 1 60); do
    git -C "$d" commit -q --allow-empty -m "p1 extra $i"
  done
  git -C "$d" checkout -q p3
  gs "$d" restack >/dev/null 2>&1 || return 1
  multi_chain_ok "$d" 61 1 1 || return 1
}

t_ambiguous_sibling_stack_is_rejected() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q p1
  git -C "$d" checkout -q -b sibling
  git -C "$d" commit -q --allow-empty -m sibling
  git -C "$d" checkout -q p1
  local out
  if out=$(gs "$d" restack 2>&1); then return 1; fi
  echo "$out" | grep -q "ambiguous stack above p1" || return 1
  echo "$out" | grep -q "p2" || return 1
  echo "$out" | grep -q "sibling" || return 1
}

t_restack_rejects_dirty_worktree_before_mutation() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q p1
  git -C "$d" commit -q --amend --allow-empty -m "p1 amended"
  printf dirty > "$d/untracked.txt"
  local p2_before out
  p2_before=$(git -C "$d" rev-parse p2)
  if out=$(gs "$d" restack 2>&1); then return 1; fi
  echo "$out" | grep -q "uncommitted changes" || return 1
  [ "$p2_before" = "$(git -C "$d" rev-parse p2)" ] || return 1
}

t_restack_rejects_existing_rebase() {
  mkrepo r; local d="$TMP/r"
  mkdir -p "$d/.git/rebase-merge"
  local out
  if out=$(gs "$d" restack 2>&1); then return 1; fi
  echo "$out" | grep -q "rebase is already in progress" || return 1
}

t_restack_rejects_stack_branch_in_other_worktree() {
  mkrepo r; local d="$TMP/r" wt="$TMP/other-worktree"
  git -C "$d" checkout -q p1
  git -C "$d" worktree add -q "$wt" p3
  git -C "$d" commit -q --amend --allow-empty -m "p1 amended"
  local p2_before out
  p2_before=$(git -C "$d" rev-parse p2)
  if out=$(gs "$d" restack 2>&1); then return 1; fi
  echo "$out" | grep -q "p3 is checked out in another worktree" || return 1
  [ "$p2_before" = "$(git -C "$d" rev-parse p2)" ] || return 1
}

t_restack_conflict_leaves_git_recovery_state() {
  local d="$TMP/conflict"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  printf 'base\n' > "$d/file.txt"
  git -C "$d" add file.txt; git -C "$d" commit -q -m base
  git -C "$d" checkout -q -b p1
  printf 'p1 old\n' > "$d/file.txt"
  git -C "$d" commit -qam p1
  git -C "$d" checkout -q -b p2
  printf 'p2 change\n' > "$d/file.txt"
  git -C "$d" commit -qam p2
  git -C "$d" checkout -q p1
  printf 'p1 amended incompatibly\n' > "$d/file.txt"
  git -C "$d" commit -qam "p1 amended" --amend
  git -C "$d" checkout -q p2
  if gs "$d" restack >/dev/null 2>&1; then return 1; fi
  [ -d "$d/.git/rebase-merge" ] || [ -d "$d/.git/rebase-apply" ] || return 1
  git -C "$d" rebase --abort >/dev/null 2>&1 || return 1
}

make_fake_gh() {
  local d="$1"
  mkdir -p "$d"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$*" in' \
    '  "repo view --json url --jq .url") echo https://github.com/o/r ;;' \
    '  *"pr list"*) echo 1 ;;' \
    '  *"--json title"*) echo title ;;' \
    '  *"--json body"*) printf "%s" "${FAKE_BODY:-body}" ;;' \
    '  api*) [ -n "${FAKE_API_CALLED:-}" ] && touch "$FAKE_API_CALLED"; exit "${FAKE_API_EXIT:-0}" ;;' \
    'esac' > "$d/gh"
  chmod +x "$d/gh"
}

add_test_origin() {
  local d="$1" remote="$TMP/remote.git"
  rm -rf "$remote"
  git clone -q --bare "$d" "$remote"
  git -C "$d" remote add origin "$remote"
  git -C "$d" fetch -q origin
}

advance_remote_main() {
  local clone="$TMP/upstream"
  rm -rf "$clone"
  git clone -q "$TMP/remote.git" "$clone"
  git -C "$clone" config user.email t@t.t
  git -C "$clone" config user.name t
  git -C "$clone" checkout -q main
  git -C "$clone" commit -q --allow-empty -m "merged stack work"
  git -C "$clone" push -q origin main
}

merge_p1_into_remote_main() {
  local clone="$TMP/upstream"
  rm -rf "$clone"
  git clone -q "$TMP/remote.git" "$clone"
  git -C "$clone" config user.email t@t.t
  git -C "$clone" config user.name t
  git -C "$clone" checkout -q main
  git -C "$clone" merge -q --no-ff origin/p1 -m "merge p1"
  git -C "$clone" push -q origin main
}

make_sync_gh() {
  local d="$1"
  mkdir -p "$d"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '[ "${FAKE_GH_FAIL:-0}" = 1 ] && { echo gh failed >&2; exit 1; }' \
    'head_branch=' \
    'while [ "$#" -gt 0 ]; do' \
    '  if [ "$1" = --head ]; then shift; head_branch=$1; fi' \
    '  shift' \
    'done' \
    'case ",${FAKE_MERGED:-}," in' \
    '  *",$head_branch,"*) echo "[{\"state\":\"MERGED\",\"mergedAt\":\"2026-01-01T00:00:00Z\"}]" ;;' \
    '  *) echo "[{\"state\":\"OPEN\",\"mergedAt\":null}]" ;;' \
    'esac' > "$d/gh"
  chmod +x "$d/gh"
}

t_sync_bottom_squash_merge_restacks_survivors() {
  mkrepo r; local d="$TMP/r" fake="$TMP/sync-gh"
  add_test_origin "$d"; advance_remote_main; make_sync_gh "$fake"
  local p1_before
  p1_before=$(git -C "$d" rev-parse p1)
  git -C "$d" checkout -q p1
  PATH="$fake:$PATH" FAKE_MERGED=p1 gs "$d" sync >/dev/null 2>&1 || return 1
  [ "$(git -C "$d" rev-parse --abbrev-ref HEAD)" = p2 ] || return 1
  [ "$p1_before" = "$(git -C "$d" rev-parse p1)" ] || return 1
  range_count "$d" origin/main p2 1 || return 1
  range_count "$d" p2 p3 1 || return 1
}

t_sync_multiple_merged_prefix_branches() {
  mkrepo r; local d="$TMP/r" fake="$TMP/sync-gh"
  add_test_origin "$d"; advance_remote_main; make_sync_gh "$fake"
  git -C "$d" checkout -q p2
  PATH="$fake:$PATH" FAKE_MERGED=p1,p2 gs "$d" sync >/dev/null 2>&1 || return 1
  [ "$(git -C "$d" rev-parse --abbrev-ref HEAD)" = p3 ] || return 1
  range_count "$d" origin/main p3 1 || return 1
  git -C "$d" show-ref --verify --quiet refs/heads/p1 || return 1
  git -C "$d" show-ref --verify --quiet refs/heads/p2 || return 1
}

t_sync_normal_merge_does_not_rediscover_merged_branch() {
  mkrepo r; local d="$TMP/r" fake="$TMP/sync-gh"
  add_test_origin "$d"; merge_p1_into_remote_main; make_sync_gh "$fake"
  git -C "$d" checkout -q p1
  PATH="$fake:$PATH" FAKE_MERGED=p1 gs "$d" sync >/dev/null 2>&1 || return 1
  local out; out=$(PATH="$fake:$PATH" gs "$d" list 2>/dev/null)
  echo "$out" | grep -q "p2 ←" || return 1
  echo "$out" | grep -q "p3 ← p2" || return 1
  if echo "$out" | grep -q "p1 ←"; then return 1; fi
}

t_sync_without_merges_rebases_and_preserves_checkout() {
  mkrepo r; local d="$TMP/r" fake="$TMP/sync-gh"
  add_test_origin "$d"; advance_remote_main; make_sync_gh "$fake"
  git -C "$d" checkout -q p2
  PATH="$fake:$PATH" gs "$d" sync >/dev/null 2>&1 || return 1
  [ "$(git -C "$d" rev-parse --abbrev-ref HEAD)" = p2 ] || return 1
  range_count "$d" origin/main p1 1 || return 1
  range_count "$d" p1 p2 1 || return 1
  range_count "$d" p2 p3 1 || return 1
}

t_sync_all_merged_checks_out_updated_trunk() {
  mkrepo r; local d="$TMP/r" fake="$TMP/sync-gh"
  add_test_origin "$d"; advance_remote_main; make_sync_gh "$fake"
  local p1_before; p1_before=$(git -C "$d" rev-parse p1)
  git -C "$d" checkout -q p3
  PATH="$fake:$PATH" FAKE_MERGED=p1,p2,p3 gs "$d" sync >/dev/null 2>&1 || return 1
  [ "$(git -C "$d" rev-parse --abbrev-ref HEAD)" = main ] || return 1
  [ "$(git -C "$d" rev-parse main)" = "$(git -C "$d" rev-parse origin/main)" ] || return 1
  [ "$p1_before" = "$(git -C "$d" rev-parse p1)" ] || return 1
}

t_sync_rejects_noncontiguous_merged_prs() {
  mkrepo r; local d="$TMP/r" fake="$TMP/sync-gh"
  add_test_origin "$d"; advance_remote_main; make_sync_gh "$fake"
  local p1_before p2_before out
  p1_before=$(git -C "$d" rev-parse p1); p2_before=$(git -C "$d" rev-parse p2)
  if out=$(PATH="$fake:$PATH" FAKE_MERGED=p2 gs "$d" sync 2>&1); then return 1; fi
  echo "$out" | grep -q "non-contiguous merged PRs" || return 1
  [ "$p1_before" = "$(git -C "$d" rev-parse p1)" ] || return 1
  [ "$p2_before" = "$(git -C "$d" rev-parse p2)" ] || return 1
}

t_sync_pr_lookup_failure_is_nonzero_without_rewrite() {
  mkrepo r; local d="$TMP/r" fake="$TMP/sync-gh"
  add_test_origin "$d"; advance_remote_main; make_sync_gh "$fake"
  local p1_before out; p1_before=$(git -C "$d" rev-parse p1)
  if out=$(PATH="$fake:$PATH" FAKE_GH_FAIL=1 gs "$d" sync 2>&1); then return 1; fi
  echo "$out" | grep -q "could not determine PR state" || return 1
  [ "$p1_before" = "$(git -C "$d" rev-parse p1)" ] || return 1
}

t_annotate_api_failure_is_nonzero_and_temp_is_cleaned() {
  mkrepo r; local d="$TMP/r" fake="$TMP/fake" temps="$TMP/temps"
  git -C "$d" checkout -q p1; git -C "$d" branch -qD p2 p3
  make_fake_gh "$fake"; mkdir -p "$temps"
  local out
  if out=$(PATH="$fake:$PATH" TMPDIR="$temps" FAKE_API_EXIT=1 gs "$d" annotate 2>&1); then return 1; fi
  echo "$out" | grep -q "1 failed" || return 1
  [ -z "$(find "$temps" -type f -print -quit)" ] || return 1
}

t_annotate_rejects_malformed_markers_without_api_call() {
  mkrepo r; local d="$TMP/r" fake="$TMP/fake" called="$TMP/api-called"
  git -C "$d" checkout -q p1; git -C "$d" branch -qD p2 p3
  make_fake_gh "$fake"
  local out
  if out=$(PATH="$fake:$PATH" FAKE_BODY='<!-- git-stack:start --> broken' FAKE_API_CALLED="$called" gs "$d" annotate 2>&1); then return 1; fi
  echo "$out" | grep -q "malformed stack markers" || return 1
  [ ! -e "$called" ] || return 1
}

# --- detached HEAD errors ---

t_detached_head_errors() {
  mkrepo r; local d="$TMP/r"
  git -C "$d" checkout -q "$(git -C "$d" rev-parse p2)"
  local out; out=$(gs "$d" list 2>&1) || true
  echo "$out" | grep -qi "detached HEAD" || return 1
  return 0
}

# --- annotate: Full PR Stack Plan block (pure functions, no gh needed) ---

# import the git-stack script as a python module and run a snippet
py_gs() {
  python3 -c "
import importlib.util
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader('gs', '$SCRIPT')
spec = importlib.util.spec_from_loader('gs', loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
$1
"
}

t_plan_block_built_correctly() {
  local out; out=$(py_gs "
md = m.build_stack_plan_markdown('hello world')
assert m.STACK_PLAN_BLOCK_START in md, 'missing start marker'
assert m.STACK_PLAN_BLOCK_END in md, 'missing end marker'
assert '<details>' in md, 'missing details tag'
assert '<summary>Full PR Stack Plan</summary>' in md, 'missing summary'
assert 'hello world' in md, 'missing content'
print('ok')
")
  [ "$out" = "ok" ] || return 1
  return 0
}

t_plan_block_idempotent_replace_and_remove() {
  local out; out=$(py_gs "
plan = m.build_stack_plan_markdown('version 1')
# append to a body
body = m.apply_stack_plan_block('top content', plan)
assert body.count(m.STACK_PLAN_BLOCK_START) == 1, body
assert 'version 1' in body
# replace with a new version (idempotent)
plan2 = m.build_stack_plan_markdown('version 2')
body = m.apply_stack_plan_block(body, plan2)
assert body.count(m.STACK_PLAN_BLOCK_START) == 1, 'duplicate block after re-annotate'
assert 'version 2' in body, 'new plan missing'
assert 'version 1' not in body, 'old plan not replaced'
# remove (simulating --no-plan)
body = m.apply_stack_plan_block(body, None)
assert m.STACK_PLAN_BLOCK_START not in body, 'plan not removed by --no-plan'
assert 'top content' in body, 'top content lost when removing plan'
print('ok')
")
  [ "$out" = "ok" ] || return 1
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
run_test "rebase preserves multi-commit branch ranges"        t_rebase_multicommit_preserves_branch_ranges
run_test "rebase updates a single-branch stack"               t_rebase_single_branch_rebases
run_test "restack single branch says nothing to restack"      t_restack_single_branch_says_nothing_to_restack
run_test "two-branch: restack after amending bottom"          t_restack_two_branch_after_amend_bottom
run_test "two-branch: status shows needs restack after amend"  t_status_two_branch_after_amend_shows_needs_restack
run_test "restack returns to the branch you were on"          t_restack_returns_to_original_branch
run_test "unrelated sibling branch excluded from stack"       t_unrelated_sibling_excluded_from_stack
run_test "restack with multiple amends preserves all"         t_restack_multiple_amends_preserves_all
run_test "multi-commit stack detects from every branch"       t_multicommit_detection_from_each_branch
run_test "restack after adds preserves each branch range"     t_restack_after_adds_preserves_branch_ranges
run_test "restack after multi-commit amend preserves ranges"  t_restack_after_multicommit_amend_preserves_range
run_test "status catches append below another branch"         t_status_after_parent_append_requires_restack
run_test "append to top branch needs no restack"              t_top_append_needs_no_restack
run_test "restack supports interior amend on middle branch"   t_restack_interior_amend_middle_branch
run_test "interior amend on bottom works from every branch"   t_restack_interior_amend_bottom_from_each_branch
run_test "restack handles mixed appends and interior amends"  t_restack_mixed_appends_and_interior_amends
run_test "multi-commit restack is idempotent"                 t_restack_multicommit_is_idempotent
run_test "tip amend below stack works from every branch"      t_tip_amend_multicommit_parent_from_every_branch
run_test "tip append below stack works from every branch"     t_tip_append_multicommit_parent_from_every_branch
run_test "tip amend then append on middle branch"             t_tip_amend_then_append_same_middle_branch
run_test "tip changes at multiple levels need one restack"    t_tip_changes_on_multiple_levels_single_restack
run_test "shell metacharacters in branch names are safe"      t_shell_metacharacters_in_branch_are_safe
run_test "restack scans beyond fifty reflog entries"          t_restack_uses_boundary_beyond_fifty_reflog_entries
run_test "ambiguous sibling stacks are rejected"              t_ambiguous_sibling_stack_is_rejected
run_test "restack rejects dirty worktree before mutation"     t_restack_rejects_dirty_worktree_before_mutation
run_test "restack rejects an existing rebase"                 t_restack_rejects_existing_rebase
run_test "restack rejects stack branch in other worktree"     t_restack_rejects_stack_branch_in_other_worktree
run_test "restack conflict leaves recoverable git state"      t_restack_conflict_leaves_git_recovery_state
run_test "annotate API failure cleans temp and exits nonzero"  t_annotate_api_failure_is_nonzero_and_temp_is_cleaned
run_test "annotate rejects malformed markers"                 t_annotate_rejects_malformed_markers_without_api_call
run_test "sync trims squash-merged bottom PR"                 t_sync_bottom_squash_merge_restacks_survivors
run_test "sync trims multiple merged prefix PRs"              t_sync_multiple_merged_prefix_branches
run_test "sync forgets normally merged bottom PR"             t_sync_normal_merge_does_not_rediscover_merged_branch
run_test "sync rebases stack when no PR is merged"            t_sync_without_merges_rebases_and_preserves_checkout
run_test "sync handles an entirely merged stack"              t_sync_all_merged_checks_out_updated_trunk
run_test "sync rejects non-contiguous merged PRs"              t_sync_rejects_noncontiguous_merged_prs
run_test "sync PR lookup failure does not rewrite"            t_sync_pr_lookup_failure_is_nonzero_without_rewrite
run_test "detached HEAD errors cleanly"                        t_detached_head_errors
run_test "plan block built with summary + content"             t_plan_block_built_correctly
run_test "plan block idempotent replace + --no-plan removal"    t_plan_block_idempotent_replace_and_remove

echo
echo "$PASS passed, $FAIL failed"

[ "$FAIL" -eq 0 ]
