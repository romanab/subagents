#!/bin/bash
# Tests for --remove-groups in bin/modify-subaccount

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_remove_groups_dry_run_single() {
  local out
  out=$(SUBAGENTS_TEST_GECOS="subagent-managed - bot" "$dir/../bin/modify-subaccount" \
    --user alice --remove-groups devs --dry-run)

  if ! echo "$out" | grep -q "gpasswd -d alice devs"; then
    echo "FAIL: expected gpasswd -d alice devs"
    echo "$out"
    return 1
  fi
}

test_remove_groups_dry_run_multiple() {
  local out
  out=$(SUBAGENTS_TEST_GECOS="subagent-managed - bot" "$dir/../bin/modify-subaccount" \
    --user alice --remove-groups devs,ops --dry-run)

  if ! echo "$out" | grep -q "gpasswd -d alice devs"; then
    echo "FAIL: expected gpasswd -d alice devs"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "gpasswd -d alice ops"; then
    echo "FAIL: expected gpasswd -d alice ops"
    echo "$out"
    return 1
  fi
}

test_remove_groups_rejects_invalid_group() {
  if SUBAGENTS_TEST_GECOS="subagent-managed - bot" "$dir/../bin/modify-subaccount" \
      --user alice --remove-groups "Bad Group" --dry-run 2>/dev/null; then
    echo "FAIL: should reject invalid group name in --remove-groups"
    return 1
  fi
}

test_remove_groups_with_extra_groups_dry_run() {
  local out
  out=$(SUBAGENTS_TEST_GECOS="subagent-managed - bot" "$dir/../bin/modify-subaccount" \
    --user alice --extra-groups newgroup --remove-groups oldgroup --dry-run)

  if ! echo "$out" | grep -q "usermod -aG newgroup alice"; then
    echo "FAIL: expected usermod -aG newgroup alice"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "gpasswd -d alice oldgroup"; then
    echo "FAIL: expected gpasswd -d alice oldgroup"
    echo "$out"
    return 1
  fi
}

test_remove_groups_rejects_non_managed_account() {
  if SUBAGENTS_TEST_GECOS="some other user" "$dir/../bin/modify-subaccount" \
      --user alice --remove-groups devs --dry-run 2>/dev/null; then
    echo "FAIL: should reject account without subagent-managed GECOS"
    return 1
  fi
}

test_remove_groups_warning_printed() {
  local out
  out=$(SUBAGENTS_TEST_GECOS="subagent-managed - bot" "$dir/../bin/modify-subaccount" \
    --user testuser --remove-groups devs --dry-run 2>&1)

  if ! echo "$out" | grep -q "WARNING:"; then
    echo "FAIL: stale-bind warning should appear"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "bwrap-config-set"; then
    echo "FAIL: warning should mention bwrap-config-set"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "pkill -u"; then
    echo "FAIL: warning should mention pkill -u to revoke live session access"
    echo "$out"
    return 1
  fi
}

test_remove_groups_no_output_when_omitted() {
  local out
  out=$(SUBAGENTS_TEST_GECOS="subagent-managed - bot" "$dir/../bin/modify-subaccount" \
    --user alice --dry-run)

  if echo "$out" | grep -q "gpasswd"; then
    echo "FAIL: expected no gpasswd command when --remove-groups not specified"
    echo "$out"
    return 1
  fi
}
