#!/bin/bash
# Tests for bin/common.sh

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$dir/../bin/common.sh"

test_common_accepts_valid_identifiers() {
  local value
  for value in alice a a1 a_b-c sub-agent-007; do
    if ! (validate_identifier "$value" "user") 2>/dev/null; then
      echo "FAIL: '$value' should be valid"
      return 1
    fi
  done
}

test_common_rejects_invalid_identifiers() {
  local value
  for value in Alice 1abc "" "has space" "a/b" "$(printf 'a%.0s' {1..33})"; do
    if (validate_identifier "$value" "user") 2>/dev/null; then
      echo "FAIL: '$value' should be invalid"
      return 1
    fi
  done
}

test_validate_comment_rejects_comma() {
  if (validate_comment "foo,bar") 2>/dev/null; then
    echo "FAIL: validate_comment should reject ','"
    return 1
  fi
}

test_validate_comment_rejects_equals() {
  if (validate_comment "foo=bar") 2>/dev/null; then
    echo "FAIL: validate_comment should reject '='"
    return 1
  fi
}
