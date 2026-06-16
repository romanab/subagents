#!/bin/bash
# Tests for bin/group-create and bin/group-delete

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_group_create_dry_run() {
  local out
  out=$("$dir/../bin/group-create" --group devs --dry-run)

  if ! echo "$out" | grep -qE "groupadd -g 5[0-9]{4} devs"; then
    echo "FAIL: expected groupadd -g <ID> devs with ID in 50000-59999"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "mkdir -p /home/agents/shared/devs"; then
    echo "FAIL: expected mkdir of shared dir"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "chmod 2770 /home/agents/shared/devs"; then
    echo "FAIL: expected chmod 2770 on shared dir"
    echo "$out"
    return 1
  fi
}

test_group_create_rejects_invalid_name() {
  if "$dir/../bin/group-create" --group "Bad Name" --dry-run 2>/dev/null; then
    echo "FAIL: should reject invalid group name"
    return 1
  fi
}

test_group_delete_dry_run() {
  local out
  out=$("$dir/../bin/group-delete" --group devs --dry-run)

  if ! echo "$out" | grep -q "groupdel devs"; then
    echo "FAIL: expected groupdel devs"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "rm -rf /home/agents/shared/devs"; then
    echo "FAIL: expected rm -rf of shared dir"
    echo "$out"
    return 1
  fi
}

test_group_delete_rejects_invalid_name() {
  if "$dir/../bin/group-delete" --group "Bad Name" --dry-run 2>/dev/null; then
    echo "FAIL: should reject invalid group name"
    return 1
  fi
}
