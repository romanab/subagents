#!/bin/bash
# Tests for bin/delete-subaccount

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_delete_dry_run_removes_home_by_default() {
  local out
  out=$(SUBAGENTS_TEST_GECOS="subagent-managed - bot" "$dir/../bin/delete-subaccount" --user alice --dry-run)

  if ! echo "$out" | grep -q "userdel -r alice"; then
    echo "FAIL: expected userdel -r alice"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "pkill -u alice"; then
    echo "FAIL: expected pkill -u alice"
    echo "$out"
    return 1
  fi
}

test_delete_dry_run_backs_up_home_by_default() {
  local out
  out=$(SUBAGENTS_TEST_GECOS="subagent-managed - bot" "$dir/../bin/delete-subaccount" --user alice --dry-run)

  if ! echo "$out" | grep -q "backup-subaccount --user alice"; then
    echo "FAIL: expected a backup-subaccount call by default"
    echo "$out"
    return 1
  fi
}

test_delete_do_not_backup_home_dir_skips_backup() {
  local out
  out=$(SUBAGENTS_TEST_GECOS="subagent-managed - bot" "$dir/../bin/delete-subaccount" --user alice --do-not-backup-home-dir --dry-run)

  if echo "$out" | grep -q "backup-subaccount"; then
    echo "FAIL: --do-not-backup-home-dir must skip the backup-subaccount call"
    echo "$out"
    return 1
  fi
}

test_delete_rejects_non_managed_account() {
  if SUBAGENTS_TEST_GECOS="root user" "$dir/../bin/delete-subaccount" --user alice --dry-run 2>/dev/null; then
    echo "FAIL: should reject account without subagent-managed GECOS"
    return 1
  fi
}

test_delete_rejects_invalid_user() {
  if "$dir/../bin/delete-subaccount" --user Alice --dry-run 2>/dev/null; then
    echo "FAIL: should reject invalid username"
    return 1
  fi
}

test_delete_dry_run_shows_force_kill() {
  local out
  out=$(SUBAGENTS_TEST_GECOS="subagent-managed - bot" \
    "$dir/../bin/delete-subaccount" --user alice --dry-run)
  if ! echo "$out" | grep -q 'pkill -KILL'; then
    echo "FAIL: expected 'pkill -KILL' in dry-run output for reliable process termination"
    echo "$out"
    return 1
  fi
}
