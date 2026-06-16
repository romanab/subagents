#!/bin/bash
# Tests for bin/subagent

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_subagent_help_lists_all_scripts() {
  local out script
  out=$("$dir/../bin/subagent" --help)

  if ! echo "$out" | grep -q "^Usage: subagent "; then
    echo "FAIL: expected a Usage line for subagent"
    echo "$out"
    return 1
  fi

  for script in create-subaccount delete-subaccount modify-subaccount setup-skeleton \
                backup-subaccount bwrap-config-apply bwrap-config-set group-create group-delete \
                exec-in show-subaccount; do
    if ! echo "$out" | grep -q "^  $script$"; then
      echo "FAIL: expected '$script' in the script list"
      echo "$out"
      return 1
    fi
  done

  if echo "$out" | grep -q "^Usage: create-subaccount "; then
    echo "FAIL: expected no per-script --help output in 'subagent --help'"
    echo "$out"
    return 1
  fi
}

test_subagent_help_script_shows_only_that_scripts_help() {
  local out
  out=$("$dir/../bin/subagent" --help group-create)

  if ! echo "$out" | grep -q "^Usage: group-create "; then
    echo "FAIL: expected aggregated --help output for 'group-create'"
    echo "$out"
    return 1
  fi

  if echo "$out" | grep -q "^Usage: subagent "; then
    echo "FAIL: expected only group-create's help, not subagent's"
    echo "$out"
    return 1
  fi

  if echo "$out" | grep -q "^Usage: create-subaccount "; then
    echo "FAIL: expected only group-create's help, not other scripts'"
    echo "$out"
    return 1
  fi
}

test_subagent_help_rejects_unknown_script() {
  if "$dir/../bin/subagent" --help not-a-real-script 2>/dev/null; then
    echo "FAIL: should reject unknown script name after --help"
    return 1
  fi
}

test_subagent_dispatches_to_non_sudo_script() {
  local out tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/skel"

  out=$(SUBAGENTS_TEST_HOME="$tmp/home" "$dir/../bin/subagent" setup-skeleton --user alice --skeleton "$tmp/skel" --dry-run)

  if ! echo "$out" | grep -q "mkdir -p $tmp/home"; then
    echo "FAIL: expected setup-skeleton dry-run output"
    echo "$out"
    return 1
  fi
}

test_subagent_dispatches_to_sudo_script_without_sudo_in_tests() {
  local out
  out=$(SUBAGENTS_TEST_SUDO_CMD="" "$dir/../bin/subagent" group-create --group devs --dry-run)

  if ! echo "$out" | grep -qE "groupadd -g 5[0-9]{4} devs"; then
    echo "FAIL: expected group-create dry-run output"
    echo "$out"
    return 1
  fi
}

test_subagent_rejects_unknown_script() {
  if "$dir/../bin/subagent" not-a-real-script 2>/dev/null; then
    echo "FAIL: should reject unknown script name"
    return 1
  fi
}

test_subagent_no_args_prints_usage_and_exits_nonzero() {
  if "$dir/../bin/subagent" 2>/dev/null; then
    echo "FAIL: should exit non-zero with no arguments"
    return 1
  fi
}
