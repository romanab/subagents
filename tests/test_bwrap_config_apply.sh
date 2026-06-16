#!/bin/bash
# Tests for bin/bwrap-config-apply

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_apply_full_network_generates_ro_binds() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  cat > "$tmp/.subagent/config" <<'EOF'
NETWORK=full
RO_BINDS=/usr /lib
RW_BINDS=
EXTRA_RO_BINDS=
EOF
  out=$(SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-apply" --user alice --dry-run)
  rm -rf "$tmp"

  if echo "$out" | grep -q -- '--unshare-net'; then
    echo "FAIL: NETWORK=full should not unshare-net"
    return 1
  fi
  if ! echo "$out" | grep -q -- '--ro-bind-try /usr /usr'; then
    echo "FAIL: expected --ro-bind-try /usr /usr"
    echo "$out"
    return 1
  fi
}

test_apply_none_network_unshares_and_binds_rw() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  cat > "$tmp/.subagent/config" <<'EOF'
NETWORK=none
RO_BINDS=/usr
RW_BINDS=/home/agents/shared/devs:/home/alice/shared/devs
EXTRA_RO_BINDS=/opt/extra
EOF
  out=$(SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-apply" --user alice --dry-run)
  rm -rf "$tmp"

  if ! echo "$out" | grep -q -- '--unshare-net'; then
    echo "FAIL: NETWORK=none should unshare-net"
    return 1
  fi
  if ! echo "$out" | grep -q -- '--bind-try /home/agents/shared/devs /home/alice/shared/devs'; then
    echo "FAIL: expected RW_BINDS bind-try"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q -- '--ro-bind-try /opt/extra /opt/extra'; then
    echo "FAIL: expected EXTRA_RO_BINDS ro-bind-try"
    echo "$out"
    return 1
  fi
}

test_apply_dry_run_does_not_write_launcher() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  cat > "$tmp/.subagent/config" <<'EOF'
NETWORK=full
RO_BINDS=/usr
RW_BINDS=
EXTRA_RO_BINDS=
EOF
  out=$(SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-apply" --user alice --dry-run)
  local existed=0
  [[ -f "$tmp/.subagent/launcher" ]] && existed=1
  rm -rf "$tmp"

  if [[ "$existed" == "1" ]]; then
    echo "FAIL: --dry-run must not write the launcher file"
    return 1
  fi
  if ! echo "$out" | grep -q "does not exist"; then
    echo "FAIL: expected '(does not exist)' marker for current launcher"
    return 1
  fi
}

test_apply_does_not_glob_expand_binds() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent" "$tmp/etc"
  touch "$tmp/etc/should-not-appear"
  cat > "$tmp/.subagent/config" <<EOF
NETWORK=full
RO_BINDS=$tmp/etc/*
RW_BINDS=
EXTRA_RO_BINDS=
EOF
  out=$(SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-apply" --user alice --dry-run)
  rm -rf "$tmp"

  if echo "$out" | grep -q "should-not-appear"; then
    echo "FAIL: RO_BINDS glob must not expand against the filesystem"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -qF -- '--ro-bind-try '"$tmp"'/etc/\* '"$tmp"'/etc/\*'; then
    echo "FAIL: expected literal glob pattern preserved in ro-bind-try"
    echo "$out"
    return 1
  fi
}

test_apply_rejects_invalid_user() {
  if "$dir/../bin/bwrap-config-apply" --user Alice --dry-run 2>/dev/null; then
    echo "FAIL: should reject invalid username"
    return 1
  fi
}

test_apply_errors_on_missing_config() {
  local tmp
  tmp=$(mktemp -d)
  if SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-apply" --user alice --dry-run 2>/dev/null; then
    rm -rf "$tmp"
    echo "FAIL: should error when .subagent/config is missing"
    return 1
  fi
  rm -rf "$tmp"
}

test_apply_launcher_has_arg_passthrough_block() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  cat > "$tmp/.subagent/config" <<'EOF'
NETWORK=full
RO_BINDS=/usr
RW_BINDS=
EXTRA_RO_BINDS=
EOF
  out=$(SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-apply" --user alice --dry-run)
  rm -rf "$tmp"

  if ! echo "$out" | grep -q 'if \[ "\$#" -gt 0 \]'; then
    echo 'FAIL: launcher must contain if [ "$#" -gt 0 ] passthrough block'
    echo "$out"
    return 1
  fi
}

test_apply_launcher_else_branch_runs_bash() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  cat > "$tmp/.subagent/config" <<'EOF'
NETWORK=full
RO_BINDS=/usr
RW_BINDS=
EXTRA_RO_BINDS=
EOF
  out=$(SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-apply" --user alice --dry-run)
  rm -rf "$tmp"

  if ! echo "$out" | grep -q 'exec bwrap.*bwrap_args'; then
    echo 'FAIL: launcher must call exec bwrap with bwrap_args array'
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q '/bin/bash -l'; then
    echo 'FAIL: launcher else branch must exec /bin/bash -l'
    echo "$out"
    return 1
  fi
}
