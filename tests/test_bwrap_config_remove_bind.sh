#!/bin/bash
# Tests for bin/bwrap-config-set --remove-bind

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

write_config_multi() {
  local file="$1"
  cat > "$file" <<'EOF'
NETWORK=full
RO_BINDS=/usr /lib /etc
RW_BINDS=/a:/b /c:/d /e:/f
EXTRA_RO_BINDS=
EOF
}

write_config_single() {
  local file="$1"
  cat > "$file" <<'EOF'
NETWORK=full
RO_BINDS=/usr
RW_BINDS=/a:/b
EXTRA_RO_BINDS=
EOF
}

test_remove_bind_dry_run_shows_updated_line() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config_multi "$tmp/.subagent/config"

  out=$(SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --remove-bind RO_BINDS /lib --dry-run)
  rm -rf "$tmp"

  if ! echo "$out" | grep -q '+ RO_BINDS=/usr /etc'; then
    echo "FAIL: expected dry-run to show /lib removed from RO_BINDS"
    echo "$out"
    return 1
  fi
}

test_remove_bind_dry_run_does_not_modify_config() {
  local tmp before after
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config_multi "$tmp/.subagent/config"
  before=$(cat "$tmp/.subagent/config")

  SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --remove-bind RO_BINDS /lib --dry-run >/dev/null
  after=$(cat "$tmp/.subagent/config")
  rm -rf "$tmp"

  if [[ "$before" != "$after" ]]; then
    echo "FAIL: --dry-run must not modify config file"
    return 1
  fi
}

test_remove_bind_entry_at_start() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config_multi "$tmp/.subagent/config"

  # chown inside bwrap-config-apply will fail in this sandbox (no agents group,
  # not root), so the overall exit status may be non-zero. Capture that
  # separately and assert on the actual config file rewrite, which happens
  # before bwrap-config-apply is invoked.
  SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --remove-bind RO_BINDS /usr >/dev/null 2>&1 || true
  out=$(cat "$tmp/.subagent/config")
  rm -rf "$tmp"

  if ! echo "$out" | grep -q '^RO_BINDS=/lib /etc$'; then
    echo "FAIL: expected /usr removed from start, remainder '/lib /etc'"
    echo "$out"
    return 1
  fi
}

test_remove_bind_entry_at_end() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config_multi "$tmp/.subagent/config"

  # chown inside bwrap-config-apply will fail in this sandbox (no agents group,
  # not root), so the overall exit status may be non-zero. Capture that
  # separately and assert on the actual config file rewrite, which happens
  # before bwrap-config-apply is invoked.
  SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --remove-bind RO_BINDS /etc >/dev/null 2>&1 || true
  out=$(cat "$tmp/.subagent/config")
  rm -rf "$tmp"

  if ! echo "$out" | grep -q '^RO_BINDS=/usr /lib$'; then
    echo "FAIL: expected /etc removed from end, remainder '/usr /lib'"
    echo "$out"
    return 1
  fi
}

test_remove_bind_only_entry_becomes_empty() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config_single "$tmp/.subagent/config"

  # chown inside bwrap-config-apply will fail in this sandbox (no agents group,
  # not root), so the overall exit status may be non-zero. Capture that
  # separately and assert on the actual config file rewrite, which happens
  # before bwrap-config-apply is invoked.
  SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --remove-bind RO_BINDS /usr >/dev/null 2>&1 || true
  out=$(cat "$tmp/.subagent/config")
  rm -rf "$tmp"

  if ! echo "$out" | grep -q '^RO_BINDS=$'; then
    echo "FAIL: expected RO_BINDS to be empty after removing only entry"
    echo "$out"
    return 1
  fi
}

test_remove_bind_entry_not_present_exits_nonzero() {
  local tmp rc errmsg
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config_single "$tmp/.subagent/config"

  rc=0
  errmsg=$(SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --remove-bind RO_BINDS /nonexistent 2>&1) || rc=$?
  rm -rf "$tmp"

  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: should exit non-zero when entry not found"
    return 1
  fi
  if ! echo "$errmsg" | grep -qi 'not found'; then
    echo "FAIL: error message should mention 'not found'"
    echo "$errmsg"
    return 1
  fi
}

test_remove_bind_network_exits_nonzero() {
  local tmp rc errmsg
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config_single "$tmp/.subagent/config"

  rc=0
  errmsg=$(SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --remove-bind NETWORK full 2>&1) || rc=$?
  rm -rf "$tmp"

  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: should exit non-zero for NETWORK (scalar key)"
    return 1
  fi
  if ! echo "$errmsg" | grep -qi 'scalar'; then
    echo "FAIL: error message should mention 'scalar'"
    echo "$errmsg"
    return 1
  fi
}

test_remove_bind_rejects_dotdot_in_value() {
  local tmp rc
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config_multi "$tmp/.subagent/config"

  rc=0
  SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --remove-bind RW_BINDS /home/agents/../shared:/sandbox 2>/dev/null || rc=$?
  rm -rf "$tmp"

  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: should exit non-zero when value contains '..'"
    return 1
  fi
}

test_remove_bind_rw_binds_middle_entry() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config_multi "$tmp/.subagent/config"

  # chown inside bwrap-config-apply will fail in this sandbox (no agents group,
  # not root), so the overall exit status may be non-zero. Capture that
  # separately and assert on the actual config file rewrite, which happens
  # before bwrap-config-apply is invoked.
  SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --remove-bind RW_BINDS /c:/d >/dev/null 2>&1 || true
  out=$(cat "$tmp/.subagent/config")
  rm -rf "$tmp"

  if ! echo "$out" | grep -q '^RW_BINDS=/a:/b /e:/f$'; then
    echo "FAIL: expected /c:/d removed from middle of RW_BINDS"
    echo "$out"
    return 1
  fi
}
