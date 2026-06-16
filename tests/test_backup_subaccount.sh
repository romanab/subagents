#!/bin/bash
# Tests for bin/backup-subaccount

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_backup_dry_run_prints_tar_and_chown() {
  local out
  out=$(SUBAGENTS_TEST_HOME="/home/alice" SUBAGENTS_TEST_BACKUP_DIR="/home/agents/backups" \
    SUBAGENTS_TEST_TIMESTAMP="20260614120000" \
    "$dir/../bin/backup-subaccount" --user alice --dry-run)

  if ! echo "$out" | grep -q "mkdir -p /home/agents/backups"; then
    echo "FAIL: expected mkdir -p of backup dir"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "tar -czf /home/agents/backups/alice-20260614120000.tar.gz -C /home alice"; then
    echo "FAIL: expected tar command archiving the home directory"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "chown agents:agents /home/agents/backups/alice-20260614120000.tar.gz"; then
    echo "FAIL: expected chown of the backup archive to agents:agents"
    echo "$out"
    return 1
  fi
}

test_backup_dry_run_does_not_create_archive() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/home"
  echo "hello" > "$tmp/home/.bashrc"

  out=$(SUBAGENTS_TEST_HOME="$tmp/home" SUBAGENTS_TEST_BACKUP_DIR="$tmp/backups" \
    SUBAGENTS_TEST_TIMESTAMP="20260614120000" \
    "$dir/../bin/backup-subaccount" --user alice --dry-run)
  local created=0
  [[ -e "$tmp/backups" ]] && created=1
  rm -rf "$tmp"

  if [[ "$created" == "1" ]]; then
    echo "FAIL: --dry-run must not create the backup directory or archive"
    echo "$out"
    return 1
  fi
}

test_backup_rejects_invalid_user() {
  if "$dir/../bin/backup-subaccount" --user Alice --dry-run 2>/dev/null; then
    echo "FAIL: should reject invalid username"
    return 1
  fi
}
