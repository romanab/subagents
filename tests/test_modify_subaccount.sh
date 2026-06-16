#!/bin/bash
# Tests for bin/modify-subaccount

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_modify_dry_run_prints_usermod_commands() {
  local out
  out=$(SUBAGENTS_TEST_GECOS="subagent-managed - bot" "$dir/../bin/modify-subaccount" \
    --user alice --extra-groups devs --comment "updated bot" --dry-run)

  if ! echo "$out" | grep -q "usermod -aG devs alice"; then
    echo "FAIL: expected usermod -aG devs alice"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "usermod -c 'subagent-managed - updated bot' alice"; then
    echo "FAIL: expected usermod -c with preserved GECOS tag"
    echo "$out"
    return 1
  fi
}

test_modify_rejects_non_managed_account() {
  if SUBAGENTS_TEST_GECOS="some other user" "$dir/../bin/modify-subaccount" --user alice --comment "x" --dry-run 2>/dev/null; then
    echo "FAIL: should reject account without subagent-managed GECOS"
    return 1
  fi
}

test_modify_rejects_invalid_group() {
  if SUBAGENTS_TEST_GECOS="subagent-managed - bot" "$dir/../bin/modify-subaccount" --user alice --extra-groups "Bad Group" --dry-run 2>/dev/null; then
    echo "FAIL: should reject invalid group name"
    return 1
  fi
}

test_modify_no_args_prints_nothing() {
  local out
  out=$(SUBAGENTS_TEST_GECOS="subagent-managed - bot" "$dir/../bin/modify-subaccount" --user alice --dry-run)

  if [[ -n "$out" ]]; then
    echo "FAIL: expected no commands when nothing to change"
    echo "$out"
    return 1
  fi
}

test_modify_rejects_colon_in_comment() {
  if SUBAGENTS_TEST_GECOS="subagent-managed - bot" "$dir/../bin/modify-subaccount" --user alice --comment "bad:comment" --dry-run 2>/dev/null; then
    echo "FAIL: should reject ':' in --comment"
    return 1
  fi
}

test_modify_rejects_newline_in_comment() {
  if SUBAGENTS_TEST_GECOS="subagent-managed - bot" "$dir/../bin/modify-subaccount" --user alice --comment $'bad\ncomment' --dry-run 2>/dev/null; then
    echo "FAIL: should reject newline in --comment"
    return 1
  fi
}

test_modify_rejects_comma_in_comment() {
  if SUBAGENTS_TEST_GECOS="subagent-managed - bot" \
      "$dir/../bin/modify-subaccount" --user alice --comment "bad,comment" --dry-run 2>/dev/null; then
    echo "FAIL: should reject ',' in --comment"
    return 1
  fi
}

test_modify_rejects_equals_in_comment() {
  if SUBAGENTS_TEST_GECOS="subagent-managed - bot" \
      "$dir/../bin/modify-subaccount" --user alice --comment "bad=comment" --dry-run 2>/dev/null; then
    echo "FAIL: should reject '=' in --comment"
    return 1
  fi
}
