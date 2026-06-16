#!/bin/bash
# Tests for bin/setup-skeleton

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_setup_skeleton_dry_run_prints_cp_and_chown() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/skel"
  echo "hello" > "$tmp/skel/.bashrc"

  out=$(SUBAGENTS_TEST_HOME="$tmp/home" "$dir/../bin/setup-skeleton" --user alice --skeleton "$tmp/skel" --dry-run)
  rm -rf "$tmp"

  if ! echo "$out" | grep -q "cp -a $tmp/skel/."; then
    echo "FAIL: expected cp -a command"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "chown -R alice:alice"; then
    echo "FAIL: expected chown -R alice:alice"
    echo "$out"
    return 1
  fi
}

test_setup_skeleton_dry_run_does_not_copy() {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/skel"
  echo "hello" > "$tmp/skel/.bashrc"

  SUBAGENTS_TEST_HOME="$tmp/home" "$dir/../bin/setup-skeleton" --user alice --skeleton "$tmp/skel" --dry-run >/dev/null
  local copied=0
  [[ -e "$tmp/home/.bashrc" ]] && copied=1
  rm -rf "$tmp"

  if [[ "$copied" == "1" ]]; then
    echo "FAIL: --dry-run must not copy files"
    return 1
  fi
}

test_setup_skeleton_errors_on_missing_skeleton_dir() {
  if "$dir/../bin/setup-skeleton" --user alice --skeleton /nonexistent --dry-run 2>/dev/null; then
    echo "FAIL: should error on missing skeleton dir"
    return 1
  fi
}

test_setup_skeleton_rejects_invalid_user() {
  if "$dir/../bin/setup-skeleton" --user Alice --dry-run 2>/dev/null; then
    echo "FAIL: should reject invalid username"
    return 1
  fi
}
