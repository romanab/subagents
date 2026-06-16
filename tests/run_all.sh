#!/bin/bash
# Runs every tests/test_*.sh file and reports pass/fail for each test_* function.
set -u

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0

for file in "$dir"/test_*.sh; do
  # shellcheck source=/dev/null
  source "$file"
  for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
    if output=$("$fn" 2>&1); then
      echo "PASS: $fn"
    else
      echo "FAIL: $fn"
      echo "$output" | sed 's/^/    /'
      fail=1
    fi
    unset -f "$fn"
  done
done

exit $fail
