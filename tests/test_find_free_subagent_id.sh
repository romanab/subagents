#!/bin/bash
# Tests for bin/find-free-subagent-id

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_find_free_subagent_id_returns_id_in_range() {
  local out
  out=$("$dir/../bin/find-free-subagent-id")

  if ! [[ "$out" =~ ^5[0-9]{4}$ ]]; then
    echo "FAIL: expected an ID in 50000-59999, got '$out'"
    return 1
  fi
}

test_find_free_subagent_id_not_in_use() {
  local out
  out=$("$dir/../bin/find-free-subagent-id")

  if getent passwd "$out" >/dev/null || getent group "$out" >/dev/null; then
    echo "FAIL: returned ID $out is already in use as a UID or GID"
    return 1
  fi
}
