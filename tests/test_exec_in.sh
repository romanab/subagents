#!/bin/bash
# Tests for bin/exec-in
# Uses PATH-prepended stub scripts to mock getent.

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Helper: create a temp dir with stub commands and set up environment.
# Default stub: alice exists and is subagent-managed.
_setup_stubs() {
  local stub_dir
  stub_dir=$(mktemp -d)

  cat > "$stub_dir/getent" <<'STUB'
#!/bin/bash
if [[ "$1" == "passwd" && "$2" == "alice" ]]; then
  echo "alice:x:50001:50001:subagent-managed - my agent:/home/alice:/home/agents/bin/subagent-shell"
  exit 0
fi
exit 1
STUB
  chmod +x "$stub_dir/getent"

  echo "$stub_dir"
}

_cleanup_stubs() {
  rm -rf "$1"
}

# Default mode dry-run: output contains "sudo -u <user> <cmd>"
test_exec_in_default_dry_run() {
  local stub_dir out
  stub_dir=$(_setup_stubs)

  out=$(PATH="$stub_dir:$PATH" "$dir/../bin/exec-in" --user alice --dry-run /bin/bash 2>&1)
  _cleanup_stubs "$stub_dir"

  if ! echo "$out" | grep -q "+ sudo -u alice /bin/bash"; then
    echo "FAIL: expected '+ sudo -u alice /bin/bash' in dry-run output"
    echo "$out"
    return 1
  fi
}

# Sandbox mode dry-run: output contains launcher path
test_exec_in_sandbox_dry_run() {
  local stub_dir out
  stub_dir=$(_setup_stubs)

  out=$(PATH="$stub_dir:$PATH" "$dir/../bin/exec-in" --user alice --sandbox --dry-run /bin/bash 2>&1)
  _cleanup_stubs "$stub_dir"

  if ! echo "$out" | grep -q "+ sudo -u alice /home/alice/.subagent/launcher /bin/bash"; then
    echo "FAIL: expected launcher path in sandbox dry-run output"
    echo "$out"
    return 1
  fi
}

# -- separator: args after -- passed through correctly in dry-run
test_exec_in_double_dash_separator() {
  local stub_dir out
  stub_dir=$(_setup_stubs)

  out=$(PATH="$stub_dir:$PATH" "$dir/../bin/exec-in" --user alice --dry-run -- /bin/echo hello world 2>&1)
  _cleanup_stubs "$stub_dir"

  if ! echo "$out" | grep -q "+ sudo -u alice /bin/echo hello world"; then
    echo "FAIL: expected args after -- to appear in dry-run output"
    echo "$out"
    return 1
  fi
}

# Sandbox mode with args after --
test_exec_in_sandbox_with_args() {
  local stub_dir out
  stub_dir=$(_setup_stubs)

  out=$(PATH="$stub_dir:$PATH" "$dir/../bin/exec-in" --user alice --sandbox --dry-run -- /bin/ls -la 2>&1)
  _cleanup_stubs "$stub_dir"

  if ! echo "$out" | grep -q "+ sudo -u alice /home/alice/.subagent/launcher /bin/ls -la"; then
    echo "FAIL: expected sandbox dry-run with args to show launcher and args"
    echo "$out"
    return 1
  fi
}

# Missing --user exits nonzero
test_exec_in_missing_user_exits_nonzero() {
  local out rc
  rc=0
  out=$("$dir/../bin/exec-in" --dry-run /bin/bash 2>&1) || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: expected non-zero exit when --user is missing"
    return 1
  fi
}

# Unknown user exits nonzero
test_exec_in_unknown_user_exits_nonzero() {
  local stub_dir out rc
  stub_dir=$(_setup_stubs)

  rc=0
  out=$(PATH="$stub_dir:$PATH" "$dir/../bin/exec-in" --user nosuchuser --dry-run /bin/bash 2>&1) || rc=$?
  _cleanup_stubs "$stub_dir"

  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: expected non-zero exit for unknown user"
    return 1
  fi
  if ! echo "$out" | grep -qi "not found\|error"; then
    echo "FAIL: expected error message for unknown user"
    echo "$out"
    return 1
  fi
}

# Account without GECOS tag exits nonzero
test_exec_in_non_managed_account_exits_nonzero() {
  local stub_dir out rc
  stub_dir=$(_setup_stubs)

  # Override getent to return a non-managed account
  cat > "$stub_dir/getent" <<'STUB'
#!/bin/bash
if [[ "$1" == "passwd" && "$2" == "bob" ]]; then
  echo "bob:x:1001:1001:just a regular user:/home/bob:/bin/bash"
  exit 0
fi
exit 1
STUB
  chmod +x "$stub_dir/getent"

  rc=0
  out=$(PATH="$stub_dir:$PATH" "$dir/../bin/exec-in" --user bob --dry-run /bin/bash 2>&1) || rc=$?
  _cleanup_stubs "$stub_dir"

  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: expected non-zero exit for account without GECOS tag"
    return 1
  fi
  if ! echo "$out" | grep -qi "not a subagent-managed\|error"; then
    echo "FAIL: expected error message for non-managed account"
    echo "$out"
    return 1
  fi
}

# Missing command (after valid --user) exits nonzero
test_exec_in_missing_command_exits_nonzero() {
  local stub_dir out rc
  stub_dir=$(_setup_stubs)

  rc=0
  out=$(PATH="$stub_dir:$PATH" "$dir/../bin/exec-in" --user alice 2>&1) || rc=$?
  _cleanup_stubs "$stub_dir"

  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: expected non-zero exit when no command is provided"
    return 1
  fi
}

# Sandbox mode with missing launcher exits nonzero with error message
test_exec_in_sandbox_missing_launcher_exits_nonzero() {
  local stub_dir tmp_home out rc
  stub_dir=$(_setup_stubs)
  tmp_home=$(mktemp -d)
  # tmp_home has no .subagent/launcher, so the check should fail

  rc=0
  out=$(PATH="$stub_dir:$PATH" SUBAGENTS_TEST_HOME="$tmp_home" "$dir/../bin/exec-in" --user alice --sandbox /bin/bash 2>&1) || rc=$?
  _cleanup_stubs "$stub_dir"
  rm -rf "$tmp_home"

  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: expected non-zero exit when launcher is missing"
    return 1
  fi
  if ! echo "$out" | grep -qi "launcher not found\|error"; then
    echo "FAIL: expected error message about missing launcher"
    echo "$out"
    return 1
  fi
}

# --help prints usage and exits 0
test_exec_in_help_exits_zero() {
  local out rc
  rc=0
  out=$("$dir/../bin/exec-in" --help 2>&1) || rc=$?

  if [[ "$rc" -ne 0 ]]; then
    echo "FAIL: --help should exit 0"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "^Usage: exec-in "; then
    echo "FAIL: --help should print a Usage line"
    echo "$out"
    return 1
  fi
}

# Invalid username is rejected
test_exec_in_invalid_user_rejected() {
  local out rc
  rc=0
  out=$("$dir/../bin/exec-in" --user InvalidUser --dry-run /bin/bash 2>&1) || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: should reject invalid username"
    return 1
  fi
}
