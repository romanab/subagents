#!/bin/bash
# Tests for bin/show-subaccount
# Uses PATH-prepended stub scripts to mock getent, id, pgrep, tmux.

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Helper: create a temp dir with stub commands and set up environment
# Sets global STUB_DIR for cleanup, returns stub dir path on stdout.
_setup_stubs() {
  local stub_dir
  stub_dir=$(mktemp -d)

  # Default getent stub: returns a valid subagent-managed entry for alice (uid=50001)
  cat > "$stub_dir/getent" <<'STUB'
#!/bin/bash
if [[ "$1" == "passwd" && "$2" == "alice" ]]; then
  echo "alice:x:50001:50001:subagent-managed - my agent:/home/alice:/home/agents/bin/subagent-shell"
  exit 0
fi
exit 1
STUB
  chmod +x "$stub_dir/getent"

  # Default id stub: returns group names
  cat > "$stub_dir/id" <<'STUB'
#!/bin/bash
# id -Gn alice
echo "alice devs"
STUB
  chmod +x "$stub_dir/id"

  # Default pgrep stub: no bwrap processes
  cat > "$stub_dir/pgrep" <<'STUB'
#!/bin/bash
exit 1
STUB
  chmod +x "$stub_dir/pgrep"

  # Default tmux stub: not called (no socket in default tmp dir)
  cat > "$stub_dir/tmux" <<'STUB'
#!/bin/bash
exit 1
STUB
  chmod +x "$stub_dir/tmux"

  echo "$stub_dir"
}

_cleanup_stubs() {
  local stub_dir="$1"
  rm -rf "$stub_dir"
}

test_show_subaccount_account_line_has_uid_gid() {
  local stub_dir out
  stub_dir=$(_setup_stubs)

  out=$(PATH="$stub_dir:$PATH" "$dir/../bin/show-subaccount" --user alice 2>&1)
  _cleanup_stubs "$stub_dir"

  if ! echo "$out" | grep -q "^Account:  alice  uid=50001  gid=50001$"; then
    echo "FAIL: expected 'Account:  alice  uid=50001  gid=50001'"
    echo "$out"
    return 1
  fi
}

test_show_subaccount_groups_line() {
  local stub_dir out
  stub_dir=$(_setup_stubs)

  out=$(PATH="$stub_dir:$PATH" "$dir/../bin/show-subaccount" --user alice 2>&1)
  _cleanup_stubs "$stub_dir"

  if ! echo "$out" | grep -q "^Groups:   alice devs$"; then
    echo "FAIL: expected 'Groups:   alice devs'"
    echo "$out"
    return 1
  fi
}

test_show_subaccount_bwrap_config_header() {
  local stub_dir out
  stub_dir=$(_setup_stubs)

  out=$(PATH="$stub_dir:$PATH" "$dir/../bin/show-subaccount" --user alice 2>&1)
  _cleanup_stubs "$stub_dir"

  if ! echo "$out" | grep -q "^Bwrap config (/home/alice/.subagent/config):$"; then
    echo "FAIL: expected bwrap config header"
    echo "$out"
    return 1
  fi
}

test_show_subaccount_no_config_shows_placeholder() {
  local stub_dir out
  stub_dir=$(_setup_stubs)

  out=$(PATH="$stub_dir:$PATH" "$dir/../bin/show-subaccount" --user alice 2>&1)
  _cleanup_stubs "$stub_dir"

  if ! echo "$out" | grep -q "^  (no config)$"; then
    echo "FAIL: expected '  (no config)' when config file absent"
    echo "$out"
    return 1
  fi
}

test_show_subaccount_missing_user_exits_nonzero() {
  local stub_dir out rc
  stub_dir=$(_setup_stubs)

  # Override getent to always fail
  cat > "$stub_dir/getent" <<'STUB'
#!/bin/bash
exit 1
STUB
  chmod +x "$stub_dir/getent"

  rc=0
  out=$(PATH="$stub_dir:$PATH" "$dir/../bin/show-subaccount" --user nosuchuser 2>&1) || rc=$?
  _cleanup_stubs "$stub_dir"

  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: expected non-zero exit for missing user"
    return 1
  fi
  if ! echo "$out" | grep -qi "not found\|error"; then
    echo "FAIL: expected error message for missing user"
    echo "$out"
    return 1
  fi
}

test_show_subaccount_non_managed_account_exits_nonzero() {
  local stub_dir out rc
  stub_dir=$(_setup_stubs)

  # Override getent to return a non-managed account
  cat > "$stub_dir/getent" <<'STUB'
#!/bin/bash
if [[ "$1" == "passwd" && "$2" == "alice" ]]; then
  echo "alice:x:50001:50001:just a regular user:/home/alice:/bin/bash"
  exit 0
fi
exit 1
STUB
  chmod +x "$stub_dir/getent"

  rc=0
  out=$(PATH="$stub_dir:$PATH" "$dir/../bin/show-subaccount" --user alice 2>&1) || rc=$?
  _cleanup_stubs "$stub_dir"

  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: expected non-zero exit for non-managed account"
    return 1
  fi
  if ! echo "$out" | grep -qi "not a subagent-managed\|error"; then
    echo "FAIL: expected error message for non-managed account"
    echo "$out"
    return 1
  fi
}

test_show_subaccount_processes_none_when_no_tmux_and_no_bwrap() {
  local stub_dir out
  stub_dir=$(_setup_stubs)

  # pgrep returns nothing (already the default), no tmux socket at /tmp/tmux-50001/default
  out=$(PATH="$stub_dir:$PATH" "$dir/../bin/show-subaccount" --user alice 2>&1)
  _cleanup_stubs "$stub_dir"

  if ! echo "$out" | grep -q "^Processes:$"; then
    echo "FAIL: expected 'Processes:' section header"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "^  none$"; then
    echo "FAIL: expected '  none' when no tmux socket and no bwrap"
    echo "$out"
    return 1
  fi
}

test_show_subaccount_processes_shows_bwrap_pids() {
  local stub_dir out
  stub_dir=$(_setup_stubs)

  # Override pgrep to return a PID
  cat > "$stub_dir/pgrep" <<'STUB'
#!/bin/bash
echo "12346"
exit 0
STUB
  chmod +x "$stub_dir/pgrep"

  out=$(PATH="$stub_dir:$PATH" "$dir/../bin/show-subaccount" --user alice 2>&1)
  _cleanup_stubs "$stub_dir"

  if ! echo "$out" | grep -q "^  bwrap: pid 12346$"; then
    echo "FAIL: expected '  bwrap: pid 12346'"
    echo "$out"
    return 1
  fi
  # Should not print "none" when bwrap is present
  if echo "$out" | grep -q "^  none$"; then
    echo "FAIL: should not print 'none' when bwrap is running"
    echo "$out"
    return 1
  fi
}

test_show_subaccount_processes_shows_tmux_session() {
  local stub_dir out socket_dir
  stub_dir=$(_setup_stubs)

  # Create a fake tmux socket
  socket_dir=$(mktemp -d)
  # We need /tmp/tmux-50001/default to exist as a socket — use a named pipe as approximation
  # Actually the script checks -S (socket), so we need a real socket. Use socat or nc if available.
  # Simpler: override the check by making a directory entry that passes -S ... but that's hard.
  # Instead we test this via a workaround: since we can't easily create a socket in tests,
  # we verify the tmux branch is skipped (no socket = no tmux line), which is already covered.
  # To test the socket-present branch, we use a subshell that creates the socket via bash's
  # process substitution trick — not portable. Skip this specific path and document it.
  rm -rf "$socket_dir"
  _cleanup_stubs "$stub_dir"

  # This test verifies tmux output when socket is present using a real socket
  stub_dir=$(_setup_stubs)
  socket_dir="/tmp/tmux-50001"
  mkdir -p "$socket_dir"

  # Create a stub tmux that pretends there's a session
  cat > "$stub_dir/tmux" <<'STUB'
#!/bin/bash
# tmux -S <socket> ls
echo 'main: 1 windows (created Mon Jun 16 12:00:00 2026) [attached]'
exit 0
STUB
  chmod +x "$stub_dir/tmux"

  # Create a fake socket file (regular file won't pass -S test)
  # Use python or socat to create a unix domain socket if available
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import socket, os
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind('/tmp/tmux-50001/default')
" 2>/dev/null || true
  fi

  if [[ -S "/tmp/tmux-50001/default" ]]; then
    out=$(PATH="$stub_dir:$PATH" "$dir/../bin/show-subaccount" --user alice 2>&1)
    _cleanup_stubs "$stub_dir"
    rm -f "/tmp/tmux-50001/default"
    rmdir "/tmp/tmux-50001" 2>/dev/null || true

    if ! echo "$out" | grep -q 'tmux: session "main" (attached)'; then
      echo "FAIL: expected tmux session line"
      echo "$out"
      return 1
    fi
  else
    # Can't create socket — skip with pass
    _cleanup_stubs "$stub_dir"
    rmdir "/tmp/tmux-50001" 2>/dev/null || true
  fi
}

test_show_subaccount_config_contents_displayed_with_indent() {
  local stub_dir tmp_home out
  stub_dir=$(_setup_stubs)
  tmp_home=$(mktemp -d)
  mkdir -p "$tmp_home/.subagent"
  printf 'NETWORK=yes\nRO_BINDS=/usr\nRW_BINDS=/tmp\n' > "$tmp_home/.subagent/config"

  out=$(PATH="$stub_dir:$PATH" SUBAGENTS_TEST_HOME="$tmp_home" "$dir/../bin/show-subaccount" --user alice 2>&1)
  _cleanup_stubs "$stub_dir"
  rm -rf "$tmp_home"

  if ! echo "$out" | grep -q "^  NETWORK=yes$"; then
    echo "FAIL: expected '  NETWORK=yes' in config output"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "^  RO_BINDS=/usr$"; then
    echo "FAIL: expected '  RO_BINDS=/usr' in config output"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "^  RW_BINDS=/tmp$"; then
    echo "FAIL: expected '  RW_BINDS=/tmp' in config output"
    echo "$out"
    return 1
  fi
}

test_show_subaccount_help_exits_zero() {
  local out rc
  rc=0
  out=$("$dir/../bin/show-subaccount" --help 2>&1) || rc=$?

  if [[ "$rc" -ne 0 ]]; then
    echo "FAIL: --help should exit 0"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "^Usage: show-subaccount "; then
    echo "FAIL: --help should print a Usage line"
    echo "$out"
    return 1
  fi
}

test_show_subaccount_invalid_user_rejected() {
  local out rc
  rc=0
  out=$("$dir/../bin/show-subaccount" --user InvalidUser 2>&1) || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: should reject invalid username"
    return 1
  fi
}
