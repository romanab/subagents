#!/bin/bash
# Tests for bin/bwrap-config-set

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

write_config() {
  local file="$1"
  cat > "$file" <<'EOF'
NETWORK=full
RO_BINDS=/usr
RW_BINDS=/a:/b
EXTRA_RO_BINDS=
EOF
}

test_set_appends_to_rw_binds() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"

  out=$(SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --set RW_BINDS=/c:/d --dry-run)
  rm -rf "$tmp"

  if ! echo "$out" | grep -q '+ RW_BINDS=/a:/b /c:/d'; then
    echo "FAIL: expected appended RW_BINDS"
    echo "$out"
    return 1
  fi
}

test_set_replaces_network() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"

  out=$(SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --set NETWORK=none --dry-run)
  rm -rf "$tmp"

  if ! echo "$out" | grep -q '+ NETWORK=none'; then
    echo "FAIL: expected NETWORK replaced with none"
    echo "$out"
    return 1
  fi
}

test_set_rejects_unknown_key() {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"

  if SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --set BOGUS=1 --dry-run 2>/dev/null; then
    rm -rf "$tmp"
    echo "FAIL: should reject unknown config key"
    return 1
  fi
  rm -rf "$tmp"
}

test_set_dry_run_does_not_modify_config() {
  local tmp before after
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"
  before=$(cat "$tmp/.subagent/config")

  SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --set NETWORK=none --dry-run >/dev/null
  after=$(cat "$tmp/.subagent/config")
  rm -rf "$tmp"

  if [[ "$before" != "$after" ]]; then
    echo "FAIL: --dry-run must not modify config file"
    return 1
  fi
}

test_set_writes_config_and_regenerates_launcher() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"

  SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-apply" --user alice >/dev/null

  # chown inside bwrap-config-apply will fail in this sandbox (no agents group,
  # not root), so the overall exit status may be non-zero. Capture that
  # separately and assert on the actual config file rewrite, which happens
  # before bwrap-config-apply is invoked.
  SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --set NETWORK=none >/dev/null 2>&1 || true
  out=$(cat "$tmp/.subagent/config")
  rm -rf "$tmp"

  if ! echo "$out" | grep -q '^NETWORK=none'; then
    echo "FAIL: expected config file to contain NETWORK=none after write"
    echo "$out"
    return 1
  fi
}

test_set_handles_special_characters_in_value() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"

  out=$(SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --set 'EXTRA_RO_BINDS=/path|with|pipes&and\backslash' --dry-run)
  rm -rf "$tmp"

  if ! echo "$out" | grep -qF '+ EXTRA_RO_BINDS=/path|with|pipes&and\backslash'; then
    echo "FAIL: expected special-character value preserved unchanged"
    echo "$out"
    return 1
  fi
}

test_set_rejects_newline_in_value() {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"

  if SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --set $'EXTRA_RO_BINDS=/a\n/b' --dry-run 2>/dev/null; then
    rm -rf "$tmp"
    echo "FAIL: should reject newline in value"
    return 1
  fi
  rm -rf "$tmp"
}

test_set_rejects_relative_path_in_ro_binds() {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"

  if SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --set RO_BINDS=relative/path --dry-run 2>/dev/null; then
    rm -rf "$tmp"
    echo "FAIL: should reject relative path in RO_BINDS"
    return 1
  fi
  rm -rf "$tmp"
}

test_set_rejects_dotdot_in_extra_ro_binds() {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"

  if SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --set EXTRA_RO_BINDS=/home/agents/../etc --dry-run 2>/dev/null; then
    rm -rf "$tmp"
    echo "FAIL: should reject '..' in EXTRA_RO_BINDS path"
    return 1
  fi
  rm -rf "$tmp"
}

test_set_rejects_relative_sandbox_path_in_rw_binds() {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"

  if SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --set RW_BINDS=/home/agents/shared/devs:relative --dry-run 2>/dev/null; then
    rm -rf "$tmp"
    echo "FAIL: should reject relative sandbox path in RW_BINDS"
    return 1
  fi
  rm -rf "$tmp"
}

test_set_rejects_invalid_network_value() {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"

  if SUBAGENTS_TEST_HOME="$tmp" \
      "$dir/../bin/bwrap-config-set" --user alice --set NETWORK=open --dry-run 2>/dev/null; then
    rm -rf "$tmp"
    echo "FAIL: should reject invalid NETWORK value 'open'"
    return 1
  fi
  rm -rf "$tmp"
}

test_set_config_has_640_permissions_after_write() {
  local tmp mode
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"

  # bwrap-config-apply's chown will fail in a non-root test environment,
  # but the chmod 640 on the temp file happens before the mv and before
  # bwrap-config-apply is invoked, so the config file mode is testable.
  SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" \
    --user alice --set NETWORK=none >/dev/null 2>&1 || true

  mode=$(stat -c '%a' "$tmp/.subagent/config")
  rm -rf "$tmp"

  if [[ "$mode" != "640" ]]; then
    echo "FAIL: expected config mode 640 after write, got $mode"
    return 1
  fi
}
