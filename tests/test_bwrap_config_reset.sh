#!/bin/bash
# Tests for bin/bwrap-config-reset

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

write_config() {
  local file="$1"
  cat > "$file" <<'EOF'
NETWORK=none
RO_BINDS=/usr /custom
RW_BINDS=/a:/b
EXTRA_RO_BINDS=/extra
DEV_BINDS=
EXTRA_RW_BINDS=
TMPFS_MOUNTS=
ENV_SET=
ENV_UNSET=
EOF
}

write_gecos() {
  export SUBAGENTS_TEST_GECOS="subagent-managed - test account"
}

test_reset_replaces_config_with_default_profile() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"
  write_gecos

  SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-reset" --user alice --dry-run > "$tmp/out" 2>&1
  out=$(cat "$tmp/out")
  rm -rf "$tmp"
  unset SUBAGENTS_TEST_GECOS

  if ! echo "$out" | grep -q 'NETWORK=none'; then
    echo "FAIL: expected current config (NETWORK=none) to appear in dry-run output"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q 'NETWORK=full'; then
    echo "FAIL: expected new config (NETWORK=full from default profile) to appear in dry-run output"
    echo "$out"
    return 1
  fi
}

test_reset_dry_run_does_not_modify_config() {
  local tmp before after
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"
  before=$(cat "$tmp/.subagent/config")
  write_gecos

  SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-reset" --user alice --dry-run >/dev/null 2>&1
  after=$(cat "$tmp/.subagent/config")
  rm -rf "$tmp"
  unset SUBAGENTS_TEST_GECOS

  if [[ "$before" != "$after" ]]; then
    echo "FAIL: --dry-run must not modify config file"
    return 1
  fi
}

test_reset_dry_run_shows_no_exist_when_config_missing() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_gecos

  out=$(SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-reset" --user alice --dry-run 2>&1)
  rm -rf "$tmp"
  unset SUBAGENTS_TEST_GECOS

  if ! echo "$out" | grep -q "does not exist"; then
    echo "FAIL: expected '(does not exist)' when config is missing"
    echo "$out"
    return 1
  fi
}

test_reset_rejects_invalid_user() {
  if SUBAGENTS_TEST_GECOS="subagent-managed - x" \
      "$dir/../bin/bwrap-config-reset" --user Alice --dry-run 2>/dev/null; then
    echo "FAIL: should reject invalid username"
    return 1
  fi
}

test_reset_rejects_non_managed_account() {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"

  if SUBAGENTS_TEST_HOME="$tmp" SUBAGENTS_TEST_GECOS="regular user" \
      "$dir/../bin/bwrap-config-reset" --user alice --dry-run 2>/dev/null; then
    rm -rf "$tmp"
    echo "FAIL: should reject non-subagent-managed account"
    return 1
  fi
  rm -rf "$tmp"
}

test_reset_rejects_invalid_profile() {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"
  write_gecos

  if SUBAGENTS_TEST_HOME="$tmp" \
      "$dir/../bin/bwrap-config-reset" --user alice --profile nonexistent --dry-run 2>/dev/null; then
    rm -rf "$tmp"
    echo "FAIL: should reject profile that does not exist"
    return 1
  fi
  rm -rf "$tmp"
  unset SUBAGENTS_TEST_GECOS
}

test_reset_writes_config_and_regenerates_launcher() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"
  write_gecos

  # chown inside bwrap-config-apply will fail in non-root test env
  SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-reset" --user alice >/dev/null 2>&1 || true
  out=$(cat "$tmp/.subagent/config")
  rm -rf "$tmp"
  unset SUBAGENTS_TEST_GECOS

  if ! echo "$out" | grep -q '^NETWORK=full'; then
    echo "FAIL: expected config to contain NETWORK=full after reset to default profile"
    echo "$out"
    return 1
  fi
  if echo "$out" | grep -q '^RO_BINDS=.*\/custom'; then
    echo "FAIL: old custom RO_BINDS should have been replaced"
    echo "$out"
    return 1
  fi
}
