#!/bin/bash
# Shared helpers for subagents scripts. Sourced, never executed directly.

readonly IDENTIFIER_RE='^[a-z][a-z0-9_-]{0,31}$'

# validate_identifier VALUE LABEL
# Exits the calling script with status 1 and an error message on stderr if
# VALUE does not match the allowed identifier pattern.
validate_identifier() {
  local value="$1" label="$2"
  if [[ ! "$value" =~ $IDENTIFIER_RE ]]; then
    echo "Error: invalid $label '$value' (must match $IDENTIFIER_RE)" >&2
    exit 1
  fi
}

# validate_comment VALUE
# Exits the calling script with status 1 and an error message on stderr if
# VALUE contains a colon or newline, both illegal in the GECOS field.
validate_comment() {
  local value="$1"
  if [[ "$value" == *:* || "$value" == *,* || "$value" == *=* || "$value" == *$'\n'* ]]; then
    echo "Error: --comment must not contain ':', ',', '=', or a newline" >&2
    exit 1
  fi
}
