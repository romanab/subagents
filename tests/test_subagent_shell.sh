#!/bin/bash
# Tests for bin/subagent-shell

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_subagent_shell_has_valid_syntax() {
  if ! bash -n "$dir/../bin/subagent-shell"; then
    echo "FAIL: bin/subagent-shell has a syntax error"
    return 1
  fi
}

test_subagent_shell_execs_launcher_in_tmux() {
  local content
  content=$(cat "$dir/../bin/subagent-shell")

  if ! echo "$content" | grep -q 'tmux new-session -A -s main'; then
    echo "FAIL: expected tmux new-session -A -s main"
    return 1
  fi
  if ! echo "$content" | grep -q '\$HOME/.subagent/launcher'; then
    echo "FAIL: expected exec of \$HOME/.subagent/launcher"
    return 1
  fi
}
