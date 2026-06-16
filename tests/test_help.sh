#!/bin/bash
# Tests that every bin/ script with a usage() supports --help

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HELP_SCRIPTS=(
  backup-subaccount
  bwrap-config-apply
  bwrap-config-set
  create-subaccount
  delete-subaccount
  exec-in
  group-create
  group-delete
  modify-subaccount
  setup-skeleton
  show-subaccount
)

test_help_exits_zero_and_shows_usage_and_options() {
  local script out
  for script in "${HELP_SCRIPTS[@]}"; do
    if ! out=$("$dir/../bin/$script" --help 2>&1); then
      echo "FAIL: $script --help exited non-zero"
      echo "$out"
      return 1
    fi
    if ! echo "$out" | grep -q "^Usage: $script "; then
      echo "FAIL: $script --help did not print a Usage line"
      echo "$out"
      return 1
    fi
    if ! echo "$out" | grep -q "^Options:"; then
      echo "FAIL: $script --help did not print an Options section"
      echo "$out"
      return 1
    fi
  done
}

test_help_short_flag_matches_long_flag() {
  local script out_short out_long
  for script in "${HELP_SCRIPTS[@]}"; do
    out_short=$("$dir/../bin/$script" -h 2>&1)
    out_long=$("$dir/../bin/$script" --help 2>&1)
    if [[ "$out_short" != "$out_long" ]]; then
      echo "FAIL: $script -h output differs from --help output"
      return 1
    fi
  done
}
