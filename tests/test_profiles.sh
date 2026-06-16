#!/bin/bash
# Tests for profiles/*.profile against bwrap-config-apply

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_default_profile_has_full_network_and_etc_binds() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  cp "$dir/../profiles/default.profile" "$tmp/.subagent/config"
  out=$(SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-apply" --user alice --dry-run)
  rm -rf "$tmp"

  if echo "$out" | grep -q -- '--unshare-net'; then
    echo "FAIL: default profile (NETWORK=full) must not unshare-net"
    return 1
  fi
  if ! echo "$out" | grep -q -- '--ro-bind-try /etc/passwd /etc/passwd'; then
    echo "FAIL: default profile must ro-bind /etc/passwd"
    echo "$out"
    return 1
  fi
}

test_network_isolated_profile_unshares_net() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  cp "$dir/../profiles/network-isolated.profile" "$tmp/.subagent/config"
  out=$(SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-apply" --user alice --dry-run)
  rm -rf "$tmp"

  if ! echo "$out" | grep -q -- '--unshare-net'; then
    echo "FAIL: network-isolated profile (NETWORK=none) must unshare-net"
    return 1
  fi
}
