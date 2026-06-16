#!/bin/bash
# Tests for bin/create-subaccount

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_create_dry_run_prints_useradd_with_gecos() {
  local out
  out=$("$dir/../bin/create-subaccount" --user alice --comment "test bot" --dry-run)

  if ! echo "$out" | grep -qE "useradd -m -u 5[0-9]{4} -g 5[0-9]{4} -s /home/agents/bin/subagent-shell -c 'subagent-managed - test bot' alice"; then
    echo "FAIL: expected useradd with GECOS tag and -u/-g IDs"
    echo "$out"
    return 1
  fi
}

test_create_dry_run_prints_groupadd_with_matching_id() {
  local out group_id useradd_uid useradd_gid
  out=$("$dir/../bin/create-subaccount" --user alice --comment "test bot" --dry-run)

  group_id=$(echo "$out" | grep -oE 'groupadd -g [0-9]+ alice' | grep -oE '[0-9]+')
  useradd_uid=$(echo "$out" | grep -oE 'useradd -m -u [0-9]+ -g [0-9]+' | awk '{print $4}')
  useradd_gid=$(echo "$out" | grep -oE 'useradd -m -u [0-9]+ -g [0-9]+' | awk '{print $6}')

  if [[ -z "$group_id" ]]; then
    echo "FAIL: expected 'groupadd -g <ID> alice' line"
    echo "$out"
    return 1
  fi
  if ! [[ "$group_id" == "$useradd_uid" && "$group_id" == "$useradd_gid" ]]; then
    echo "FAIL: expected groupadd ID ($group_id) to match useradd -u ($useradd_uid) and -g ($useradd_gid)"
    echo "$out"
    return 1
  fi
  if ! [[ "$group_id" =~ ^5[0-9]{4}$ ]]; then
    echo "FAIL: expected ID in 50000-59999, got '$group_id'"
    return 1
  fi
}

test_create_dry_run_includes_extra_groups() {
  local out
  out=$("$dir/../bin/create-subaccount" --user alice --extra-groups devs,ops --dry-run)

  if ! echo "$out" | grep -q -- '-G devs,ops'; then
    echo "FAIL: expected -G devs,ops in useradd command"
    echo "$out"
    return 1
  fi
}

test_create_dry_run_references_profile() {
  local out
  out=$("$dir/../bin/create-subaccount" --user alice --profile network-isolated --dry-run)

  if ! echo "$out" | grep -q "profiles/network-isolated.profile"; then
    echo "FAIL: expected reference to chosen profile file"
    echo "$out"
    return 1
  fi
}

test_create_rejects_invalid_user() {
  if "$dir/../bin/create-subaccount" --user Alice --dry-run 2>/dev/null; then
    echo "FAIL: should reject invalid username"
    return 1
  fi
}

test_create_rejects_invalid_extra_group() {
  if "$dir/../bin/create-subaccount" --user alice --extra-groups "Bad Group" --dry-run 2>/dev/null; then
    echo "FAIL: should reject invalid group name"
    return 1
  fi
}

test_create_rejects_invalid_profile() {
  if "$dir/../bin/create-subaccount" --user alice --profile "Bad Profile" --dry-run 2>/dev/null; then
    echo "FAIL: should reject invalid profile name"
    return 1
  fi
}

test_create_rejects_colon_in_comment() {
  if "$dir/../bin/create-subaccount" --user alice --comment "bad:comment" --dry-run 2>/dev/null; then
    echo "FAIL: should reject ':' in --comment"
    return 1
  fi
}

test_create_rejects_newline_in_comment() {
  if "$dir/../bin/create-subaccount" --user alice --comment $'bad\ncomment' --dry-run 2>/dev/null; then
    echo "FAIL: should reject newline in --comment"
    return 1
  fi
}

test_create_rejects_comma_in_comment() {
  if "$dir/../bin/create-subaccount" --user alice --comment "bad,comment" --dry-run 2>/dev/null; then
    echo "FAIL: should reject ',' in --comment"
    return 1
  fi
}

test_create_rejects_equals_in_comment() {
  if "$dir/../bin/create-subaccount" --user alice --comment "bad=comment" --dry-run 2>/dev/null; then
    echo "FAIL: should reject '=' in --comment"
    return 1
  fi
}

test_create_dry_run_shows_sticky_bit() {
  local out
  out=$("$dir/../bin/create-subaccount" --user alice --dry-run)
  if ! echo "$out" | grep -q 'chmod +t'; then
    echo "FAIL: expected 'chmod +t' in dry-run output"
    echo "$out"
    return 1
  fi
}
