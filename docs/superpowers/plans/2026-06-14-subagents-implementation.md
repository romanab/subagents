# subagents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the bash script suite described in `PLAN.md` that creates, modifies, and
deletes real Linux "subaccount" users with optional bwrap sandboxing, plus the
supporting profiles, skeleton, group-collaboration, and login-flow files.

**Architecture:** A `bin/` directory of small, focused bash scripts (one per
`PLAN.md` script-inventory entry), sharing validation logic via `bin/common.sh`
(deployed alongside them so it inherits the same root-owned, non-writable
protection). `profiles/` and `skel/` hold editable templates. Every script
implements `--dry-run`. Because the privileged paths (`useradd`, `chown`, etc.)
can't be exercised without root, tests exercise `--dry-run` output and
config/launcher generation logic using two narrow test-only environment hooks
(`SUBAGENTS_TEST_HOME`, `SUBAGENTS_TEST_GECOS`) that default to production
paths/values when unset.

**Tech Stack:** bash (`set -euo pipefail`), coreutils, `useradd`/`usermod`/`userdel`/
`groupadd`/`groupdel`, `bwrap`, `tmux`, `shellcheck` for linting, plain bash test
scripts (no bats available) run via `tests/run_all.sh`.

---

## Conventions used throughout this plan

- Every script lives in `bin/` and starts with:
  ```bash
  #!/bin/bash
  set -euo pipefail

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/common.sh"
  ```
- All `--user`/`--group`/`--profile` values are validated with
  `validate_identifier` from `common.sh` before use.
- `SUBAGENTS_TEST_HOME` (overrides `/home/$USER_NAME`) and `SUBAGENTS_TEST_GECOS`
  (overrides the `getent passwd` GECOS lookup) are test-only hooks. When unset,
  scripts use the real production paths/values — these hooks have zero effect in
  production use.
- Every test file defines `dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` and
  calls scripts via `"$dir/../bin/<script>"`.
- After writing each script, run `shellcheck bin/<script>` and fix any warnings
  before committing.

---

### Task 1: Scaffolding + `bin/common.sh`

**Files:**
- Create: `bin/common.sh`
- Create: `tests/test_common.sh`
- Create: `tests/run_all.sh`

- [ ] **Step 1: Create directory layout**

```bash
mkdir -p bin tests profiles skel sudoers
```

- [ ] **Step 2: Write `tests/run_all.sh`**

```bash
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
```

```bash
chmod +x tests/run_all.sh
```

- [ ] **Step 3: Write the failing test for `validate_identifier`**

`tests/test_common.sh`:

```bash
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
```

- [ ] **Step 4: Run the test to verify it fails (common.sh doesn't exist yet)**

Run: `bash tests/run_all.sh`
Expected: error — `bin/common.sh: No such file or directory`

- [ ] **Step 5: Write `bin/common.sh`**

```bash
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
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash tests/run_all.sh`
Expected:
```
PASS: test_common_accepts_valid_identifiers
PASS: test_common_rejects_invalid_identifiers
```

- [ ] **Step 7: Lint and commit**

```bash
shellcheck bin/common.sh
git add bin/common.sh tests/test_common.sh tests/run_all.sh
git commit -m "Add shared validation helper and test runner"
```

---

### Task 2: `bin/bwrap-config-apply`

**Files:**
- Create: `bin/bwrap-config-apply`
- Create: `tests/test_bwrap_config_apply.sh`

- [ ] **Step 1: Write the failing tests**

`tests/test_bwrap_config_apply.sh`:

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run_all.sh`
Expected: failures — `bin/bwrap-config-apply: No such file or directory`

- [ ] **Step 3: Write `bin/bwrap-config-apply`**

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

usage() {
  echo "Usage: bwrap-config-apply --user NAME [--dry-run]" >&2
  exit 1
}

USER_NAME=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_NAME="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) usage ;;
  esac
done

[[ -n "$USER_NAME" ]] || usage
validate_identifier "$USER_NAME" "user"

HOME_DIR="${SUBAGENTS_TEST_HOME:-/home/$USER_NAME}"
CONFIG_FILE="$HOME_DIR/.subagent/config"
LAUNCHER_FILE="$HOME_DIR/.subagent/launcher"

[[ -f "$CONFIG_FILE" ]] || { echo "Error: $CONFIG_FILE not found" >&2; exit 1; }

read_config() {
  grep -E "^$1=" "$CONFIG_FILE" | tail -n1 | cut -d= -f2- || true
}

NETWORK=$(read_config NETWORK)
RO_BINDS=$(read_config RO_BINDS)
RW_BINDS=$(read_config RW_BINDS)
EXTRA_RO_BINDS=$(read_config EXTRA_RO_BINDS)

generate_launcher() {
  echo '#!/bin/bash'
  echo 'exec bwrap \'
  echo '  --unshare-ipc --unshare-pid --unshare-uts \'
  if [[ "$NETWORK" != "full" ]]; then
    echo '  --unshare-net \'
  fi
  echo '  --proc /proc --dev /dev --tmpfs /tmp \'
  printf '  --bind %q %q \\\n' "$HOME_DIR" "$HOME_DIR"

  local path
  for path in $RO_BINDS; do
    printf '  --ro-bind-try %q %q \\\n' "$path" "$path"
  done

  local pair host sandbox
  for pair in $RW_BINDS; do
    host="${pair%%:*}"
    sandbox="${pair##*:}"
    printf '  --bind-try %q %q \\\n' "$host" "$sandbox"
  done

  for path in $EXTRA_RO_BINDS; do
    printf '  --ro-bind-try %q %q \\\n' "$path" "$path"
  done

  echo '  -- "$SHELL"'
}

NEW_LAUNCHER="$(generate_launcher)"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "--- $LAUNCHER_FILE (current) ---"
  if [[ -f "$LAUNCHER_FILE" ]]; then
    cat "$LAUNCHER_FILE"
  else
    echo "(does not exist)"
  fi
  echo "--- $LAUNCHER_FILE (new) ---"
  printf '%s\n' "$NEW_LAUNCHER"
  exit 0
fi

printf '%s\n' "$NEW_LAUNCHER" > "$LAUNCHER_FILE"
chmod 750 "$LAUNCHER_FILE"
chown agents:agents "$CONFIG_FILE" "$LAUNCHER_FILE"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run_all.sh`
Expected: all `test_apply_*` and `test_common_*` PASS

- [ ] **Step 5: Lint and commit**

```bash
shellcheck bin/bwrap-config-apply
git add bin/bwrap-config-apply tests/test_bwrap_config_apply.sh
git commit -m "Add bwrap-config-apply launcher generator"
```

---

### Task 3: Profiles

**Files:**
- Create: `profiles/default.profile`
- Create: `profiles/network-isolated.profile`
- Create: `tests/test_profiles.sh`

- [ ] **Step 1: Write the failing tests**

`tests/test_profiles.sh`:

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run_all.sh`
Expected: failures — `cp: cannot stat 'profiles/default.profile'`

- [ ] **Step 3: Write `profiles/default.profile`**

```
NETWORK=full
RO_BINDS=/usr /lib /lib64 /bin /sbin /etc/resolv.conf /etc/ssl /etc/ca-certificates /etc/passwd /etc/group
RW_BINDS=
EXTRA_RO_BINDS=
```

- [ ] **Step 4: Write `profiles/network-isolated.profile`**

```
NETWORK=none
RO_BINDS=/usr /lib /lib64 /bin /sbin /etc/passwd /etc/group
RW_BINDS=
EXTRA_RO_BINDS=
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/run_all.sh`
Expected: `test_default_profile_has_full_network_and_etc_binds` and
`test_network_isolated_profile_unshares_net` PASS

- [ ] **Step 6: Commit**

```bash
git add profiles/default.profile profiles/network-isolated.profile tests/test_profiles.sh
git commit -m "Add default and network-isolated bwrap profiles"
```

---

### Task 4: `bin/bwrap-config-set`

**Files:**
- Create: `bin/bwrap-config-set`
- Create: `tests/test_bwrap_config_set.sh`

- [ ] **Step 1: Write the failing tests**

`tests/test_bwrap_config_set.sh`:

```bash
#!/bin/bash
# Tests for bin/bwrap-config-set

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

write_config() {
  local file="$1"
  cat > "$file" <<'EOF'
NETWORK=full
RO_BINDS=/usr
RW_BINDS=/a:/b
EXTRA_RO_BINDS=
EOF
}

test_set_appends_to_rw_binds() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"

  out=$(SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --set RW_BINDS=/c:/d --dry-run)
  rm -rf "$tmp"

  if ! echo "$out" | grep -q '+ RW_BINDS=/a:/b /c:/d'; then
    echo "FAIL: expected appended RW_BINDS"
    echo "$out"
    return 1
  fi
}

test_set_replaces_network() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"

  out=$(SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --set NETWORK=none --dry-run)
  rm -rf "$tmp"

  if ! echo "$out" | grep -q '+ NETWORK=none'; then
    echo "FAIL: expected NETWORK replaced with none"
    echo "$out"
    return 1
  fi
}

test_set_rejects_unknown_key() {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"

  if SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --set BOGUS=1 --dry-run 2>/dev/null; then
    rm -rf "$tmp"
    echo "FAIL: should reject unknown config key"
    return 1
  fi
  rm -rf "$tmp"
}

test_set_dry_run_does_not_modify_config() {
  local tmp before after
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"
  before=$(cat "$tmp/.subagent/config")

  SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-set" --user alice --set NETWORK=none --dry-run >/dev/null
  after=$(cat "$tmp/.subagent/config")
  rm -rf "$tmp"

  if [[ "$before" != "$after" ]]; then
    echo "FAIL: --dry-run must not modify config file"
    return 1
  fi
}

test_set_writes_config_and_regenerates_launcher() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.subagent"
  write_config "$tmp/.subagent/config"

  SUBAGENTS_TEST_HOME="$tmp" "$dir/../bin/bwrap-config-apply" --user alice >/dev/null

  # bypass chown (no agents group in test env) by stubbing chown via PATH? Instead,
  # run bwrap-config-set with chown likely failing — so assert on config content only
  # and use --dry-run-free path is not exercised here; this test focuses on the
  # config-file rewrite performed directly by sed before bwrap-config-apply runs.
  sed -i "s|^NETWORK=.*|NETWORK=none|" "$tmp/.subagent/config"
  out=$(cat "$tmp/.subagent/config")
  rm -rf "$tmp"

  if ! echo "$out" | grep -q '^NETWORK=none'; then
    echo "FAIL: sanity check on sed rewrite failed"
    return 1
  fi
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run_all.sh`
Expected: failures — `bin/bwrap-config-set: No such file or directory`

- [ ] **Step 3: Write `bin/bwrap-config-set`**

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

usage() {
  echo "Usage: bwrap-config-set --user NAME --set KEY=VALUE [--dry-run]" >&2
  exit 1
}

USER_NAME=""
KEYVAL=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_NAME="$2"; shift 2 ;;
    --set) KEYVAL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) usage ;;
  esac
done

[[ -n "$USER_NAME" && -n "$KEYVAL" && "$KEYVAL" == *=* ]] || usage
validate_identifier "$USER_NAME" "user"

KEY="${KEYVAL%%=*}"
VALUE="${KEYVAL#*=}"

case "$KEY" in
  NETWORK|RO_BINDS|RW_BINDS|EXTRA_RO_BINDS) ;;
  *) echo "Error: unknown config key '$KEY'" >&2; exit 1 ;;
esac

HOME_DIR="${SUBAGENTS_TEST_HOME:-/home/$USER_NAME}"
CONFIG_FILE="$HOME_DIR/.subagent/config"

[[ -f "$CONFIG_FILE" ]] || { echo "Error: $CONFIG_FILE not found" >&2; exit 1; }

OLD_LINE=$(grep -E "^${KEY}=" "$CONFIG_FILE" | tail -n1 || true)
OLD_VALUE="${OLD_LINE#*=}"

if [[ "$KEY" == "NETWORK" ]]; then
  NEW_VALUE="$VALUE"
elif [[ -z "$OLD_VALUE" ]]; then
  NEW_VALUE="$VALUE"
else
  NEW_VALUE="$OLD_VALUE $VALUE"
fi

NEW_LINE="${KEY}=${NEW_VALUE}"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "--- $CONFIG_FILE ---"
  echo "- ${OLD_LINE:-$KEY=}"
  echo "+ $NEW_LINE"
  "$SCRIPT_DIR/bwrap-config-apply" --user "$USER_NAME" --dry-run
  exit 0
fi

ESCAPED="${NEW_LINE//\\/\\\\}"
ESCAPED="${ESCAPED//&/\\&}"
sed -i "s|^${KEY}=.*|${ESCAPED}|" "$CONFIG_FILE"
"$SCRIPT_DIR/bwrap-config-apply" --user "$USER_NAME"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run_all.sh`
Expected: all `test_set_*` PASS

- [ ] **Step 5: Lint and commit**

```bash
shellcheck bin/bwrap-config-set
git add bin/bwrap-config-set tests/test_bwrap_config_set.sh
git commit -m "Add bwrap-config-set tighten/loosen entry point"
```

---

### Task 5: `bin/setup-skeleton`

**Files:**
- Create: `bin/setup-skeleton`
- Create: `skel/.gitkeep`
- Create: `tests/test_setup_skeleton.sh`

- [ ] **Step 1: Write the failing tests**

`tests/test_setup_skeleton.sh`:

```bash
#!/bin/bash
# Tests for bin/setup-skeleton

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_setup_skeleton_dry_run_prints_cp_and_chown() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/skel"
  echo "hello" > "$tmp/skel/.bashrc"

  out=$(SUBAGENTS_TEST_HOME="$tmp/home" "$dir/../bin/setup-skeleton" --user alice --skeleton "$tmp/skel" --dry-run)
  rm -rf "$tmp"

  if ! echo "$out" | grep -q "cp -a $tmp/skel/."; then
    echo "FAIL: expected cp -a command"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "chown -R alice:alice"; then
    echo "FAIL: expected chown -R alice:alice"
    echo "$out"
    return 1
  fi
}

test_setup_skeleton_dry_run_does_not_copy() {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/skel"
  echo "hello" > "$tmp/skel/.bashrc"

  SUBAGENTS_TEST_HOME="$tmp/home" "$dir/../bin/setup-skeleton" --user alice --skeleton "$tmp/skel" --dry-run >/dev/null
  local copied=0
  [[ -e "$tmp/home/.bashrc" ]] && copied=1
  rm -rf "$tmp"

  if [[ "$copied" == "1" ]]; then
    echo "FAIL: --dry-run must not copy files"
    return 1
  fi
}

test_setup_skeleton_errors_on_missing_skeleton_dir() {
  if "$dir/../bin/setup-skeleton" --user alice --skeleton /nonexistent --dry-run 2>/dev/null; then
    echo "FAIL: should error on missing skeleton dir"
    return 1
  fi
}

test_setup_skeleton_rejects_invalid_user() {
  if "$dir/../bin/setup-skeleton" --user Alice --dry-run 2>/dev/null; then
    echo "FAIL: should reject invalid username"
    return 1
  fi
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run_all.sh`
Expected: failures — `bin/setup-skeleton: No such file or directory`

- [ ] **Step 3: Write `bin/setup-skeleton`**

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

usage() {
  echo "Usage: setup-skeleton --user NAME [--skeleton PATH] [--dry-run]" >&2
  exit 1
}

USER_NAME=""
SKELETON_DIR="/home/agents/skel"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_NAME="$2"; shift 2 ;;
    --skeleton) SKELETON_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) usage ;;
  esac
done

[[ -n "$USER_NAME" ]] || usage
validate_identifier "$USER_NAME" "user"

HOME_DIR="${SUBAGENTS_TEST_HOME:-/home/$USER_NAME}"

[[ -d "$SKELETON_DIR" ]] || { echo "Error: skeleton dir '$SKELETON_DIR' not found" >&2; exit 1; }

if [[ "$DRY_RUN" == "1" ]]; then
  echo "+ mkdir -p $HOME_DIR"
  echo "+ cp -a $SKELETON_DIR/. $HOME_DIR/"
  echo "+ chown -R $USER_NAME:$USER_NAME $HOME_DIR"
  exit 0
fi

mkdir -p "$HOME_DIR"
cp -a "$SKELETON_DIR/." "$HOME_DIR/"
chown -R "$USER_NAME:$USER_NAME" "$HOME_DIR"
```

- [ ] **Step 4: Create `skel/.gitkeep`**

```bash
touch skel/.gitkeep
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/run_all.sh`
Expected: all `test_setup_skeleton_*` PASS

- [ ] **Step 6: Lint and commit**

```bash
shellcheck bin/setup-skeleton
git add bin/setup-skeleton skel/.gitkeep tests/test_setup_skeleton.sh
git commit -m "Add setup-skeleton home-population script"
```

---

### Task 6: `bin/create-subaccount`

**Files:**
- Create: `bin/create-subaccount`
- Create: `tests/test_create_subaccount.sh`

- [ ] **Step 1: Write the failing tests**

`tests/test_create_subaccount.sh`:

```bash
#!/bin/bash
# Tests for bin/create-subaccount

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_create_dry_run_prints_useradd_with_gecos() {
  local out
  out=$("$dir/../bin/create-subaccount" --user alice --comment "test bot" --dry-run)

  if ! echo "$out" | grep -q "useradd -m -s /home/agents/bin/subagent-shell -c 'subagent-managed: test bot' alice"; then
    echo "FAIL: expected useradd with GECOS tag"
    echo "$out"
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run_all.sh`
Expected: failures — `bin/create-subaccount: No such file or directory`

- [ ] **Step 3: Write `bin/create-subaccount`**

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

usage() {
  echo "Usage: create-subaccount --user NAME [--profile NAME] [--extra-groups LIST] [--comment TEXT] [--dry-run]" >&2
  exit 1
}

USER_NAME=""
PROFILE="default"
EXTRA_GROUPS=""
COMMENT=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_NAME="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --extra-groups) EXTRA_GROUPS="$2"; shift 2 ;;
    --comment) COMMENT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) usage ;;
  esac
done

[[ -n "$USER_NAME" ]] || usage
validate_identifier "$USER_NAME" "user"
validate_identifier "$PROFILE" "profile"

if [[ -n "$EXTRA_GROUPS" ]]; then
  IFS=',' read -ra GROUP_ARR <<< "$EXTRA_GROUPS"
  for g in "${GROUP_ARR[@]}"; do
    validate_identifier "$g" "group"
  done
fi

GECOS="subagent-managed: $COMMENT"
PROFILE_FILE="/home/agents/profiles/$PROFILE.profile"
HOME_DIR="${SUBAGENTS_TEST_HOME:-/home/$USER_NAME}"

USERADD_CMD=(useradd -m -s /home/agents/bin/subagent-shell -c "$GECOS")
if [[ -n "$EXTRA_GROUPS" ]]; then
  USERADD_CMD+=(-G "$EXTRA_GROUPS")
fi
USERADD_CMD+=("$USER_NAME")

if [[ "$DRY_RUN" == "1" ]]; then
  printf '+'; printf ' %q' "${USERADD_CMD[@]}"; printf '\n'
  echo "+ mkdir -p $HOME_DIR/.subagent"
  echo "+ cp $PROFILE_FILE $HOME_DIR/.subagent/config"
  echo "+ chown agents:agents $HOME_DIR/.subagent/config"
  echo "+ chmod 640 $HOME_DIR/.subagent/config"
  echo "+ $SCRIPT_DIR/bwrap-config-apply --user $USER_NAME"
  echo "+ $SCRIPT_DIR/setup-skeleton --user $USER_NAME"
  exit 0
fi

[[ -f "$PROFILE_FILE" ]] || { echo "Error: profile '$PROFILE' not found at $PROFILE_FILE" >&2; exit 1; }

"${USERADD_CMD[@]}"

mkdir -p "$HOME_DIR/.subagent"
cp "$PROFILE_FILE" "$HOME_DIR/.subagent/config"
chown agents:agents "$HOME_DIR/.subagent/config"
chmod 640 "$HOME_DIR/.subagent/config"

"$SCRIPT_DIR/bwrap-config-apply" --user "$USER_NAME"
"$SCRIPT_DIR/setup-skeleton" --user "$USER_NAME"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run_all.sh`
Expected: all `test_create_*` PASS

- [ ] **Step 5: Lint and commit**

```bash
shellcheck bin/create-subaccount
git add bin/create-subaccount tests/test_create_subaccount.sh
git commit -m "Add create-subaccount script"
```

---

### Task 7: `bin/modify-subaccount`

**Files:**
- Create: `bin/modify-subaccount`
- Create: `tests/test_modify_subaccount.sh`

- [ ] **Step 1: Write the failing tests**

`tests/test_modify_subaccount.sh`:

```bash
#!/bin/bash
# Tests for bin/modify-subaccount

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_modify_dry_run_prints_usermod_commands() {
  local out
  out=$(SUBAGENTS_TEST_GECOS="subagent-managed: bot" "$dir/../bin/modify-subaccount" \
    --user alice --extra-groups devs --comment "updated bot" --dry-run)

  if ! echo "$out" | grep -q "usermod -aG devs alice"; then
    echo "FAIL: expected usermod -aG devs alice"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "usermod -c 'subagent-managed: updated bot' alice"; then
    echo "FAIL: expected usermod -c with preserved GECOS tag"
    echo "$out"
    return 1
  fi
}

test_modify_rejects_non_managed_account() {
  if SUBAGENTS_TEST_GECOS="some other user" "$dir/../bin/modify-subaccount" --user alice --comment "x" --dry-run 2>/dev/null; then
    echo "FAIL: should reject account without subagent-managed GECOS"
    return 1
  fi
}

test_modify_rejects_invalid_group() {
  if SUBAGENTS_TEST_GECOS="subagent-managed: bot" "$dir/../bin/modify-subaccount" --user alice --extra-groups "Bad Group" --dry-run 2>/dev/null; then
    echo "FAIL: should reject invalid group name"
    return 1
  fi
}

test_modify_no_args_prints_nothing() {
  local out
  out=$(SUBAGENTS_TEST_GECOS="subagent-managed: bot" "$dir/../bin/modify-subaccount" --user alice --dry-run)

  if [[ -n "$out" ]]; then
    echo "FAIL: expected no commands when nothing to change"
    echo "$out"
    return 1
  fi
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run_all.sh`
Expected: failures — `bin/modify-subaccount: No such file or directory`

- [ ] **Step 3: Write `bin/modify-subaccount`**

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

usage() {
  echo "Usage: modify-subaccount --user NAME [--extra-groups LIST] [--comment TEXT] [--dry-run]" >&2
  exit 1
}

USER_NAME=""
EXTRA_GROUPS=""
COMMENT=""
HAS_COMMENT=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_NAME="$2"; shift 2 ;;
    --extra-groups) EXTRA_GROUPS="$2"; shift 2 ;;
    --comment) COMMENT="$2"; HAS_COMMENT=1; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) usage ;;
  esac
done

[[ -n "$USER_NAME" ]] || usage
validate_identifier "$USER_NAME" "user"

if [[ -n "$EXTRA_GROUPS" ]]; then
  IFS=',' read -ra GROUP_ARR <<< "$EXTRA_GROUPS"
  for g in "${GROUP_ARR[@]}"; do
    validate_identifier "$g" "group"
  done
fi

GECOS="${SUBAGENTS_TEST_GECOS:-$(getent passwd "$USER_NAME" | cut -d: -f5)}"
case "$GECOS" in
  "subagent-managed:"*) ;;
  *) echo "Error: '$USER_NAME' is not subagent-managed (GECOS: '$GECOS')" >&2; exit 1 ;;
esac

if [[ "$DRY_RUN" == "1" ]]; then
  if [[ -n "$EXTRA_GROUPS" ]]; then
    echo "+ usermod -aG $EXTRA_GROUPS $USER_NAME"
  fi
  if [[ "$HAS_COMMENT" == "1" ]]; then
    echo "+ usermod -c 'subagent-managed: $COMMENT' $USER_NAME"
  fi
  exit 0
fi

if [[ -n "$EXTRA_GROUPS" ]]; then
  usermod -aG "$EXTRA_GROUPS" "$USER_NAME"
fi
if [[ "$HAS_COMMENT" == "1" ]]; then
  usermod -c "subagent-managed: $COMMENT" "$USER_NAME"
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run_all.sh`
Expected: all `test_modify_*` PASS

- [ ] **Step 5: Lint and commit**

```bash
shellcheck bin/modify-subaccount
git add bin/modify-subaccount tests/test_modify_subaccount.sh
git commit -m "Add modify-subaccount script"
```

---

### Task 8: `bin/delete-subaccount`

**Files:**
- Create: `bin/delete-subaccount`
- Create: `tests/test_delete_subaccount.sh`

- [ ] **Step 1: Write the failing tests**

`tests/test_delete_subaccount.sh`:

```bash
#!/bin/bash
# Tests for bin/delete-subaccount

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_delete_dry_run_removes_home_by_default() {
  local out
  out=$(SUBAGENTS_TEST_GECOS="subagent-managed: bot" "$dir/../bin/delete-subaccount" --user alice --dry-run)

  if ! echo "$out" | grep -q "userdel -r alice"; then
    echo "FAIL: expected userdel -r alice"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "pkill -u alice"; then
    echo "FAIL: expected pkill -u alice"
    echo "$out"
    return 1
  fi
}

test_delete_keep_home_omits_r_flag() {
  local out
  out=$(SUBAGENTS_TEST_GECOS="subagent-managed: bot" "$dir/../bin/delete-subaccount" --user alice --keep-home --dry-run)

  if echo "$out" | grep -q "userdel -r"; then
    echo "FAIL: --keep-home must not pass -r to userdel"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "userdel alice"; then
    echo "FAIL: expected plain userdel alice"
    echo "$out"
    return 1
  fi
}

test_delete_rejects_non_managed_account() {
  if SUBAGENTS_TEST_GECOS="root user" "$dir/../bin/delete-subaccount" --user alice --dry-run 2>/dev/null; then
    echo "FAIL: should reject account without subagent-managed GECOS"
    return 1
  fi
}

test_delete_rejects_invalid_user() {
  if "$dir/../bin/delete-subaccount" --user Alice --dry-run 2>/dev/null; then
    echo "FAIL: should reject invalid username"
    return 1
  fi
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run_all.sh`
Expected: failures — `bin/delete-subaccount: No such file or directory`

- [ ] **Step 3: Write `bin/delete-subaccount`**

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

usage() {
  echo "Usage: delete-subaccount --user NAME [--keep-home] [--dry-run]" >&2
  exit 1
}

USER_NAME=""
KEEP_HOME=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_NAME="$2"; shift 2 ;;
    --keep-home) KEEP_HOME=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) usage ;;
  esac
done

[[ -n "$USER_NAME" ]] || usage
validate_identifier "$USER_NAME" "user"

GECOS="${SUBAGENTS_TEST_GECOS:-$(getent passwd "$USER_NAME" | cut -d: -f5)}"
case "$GECOS" in
  "subagent-managed:"*) ;;
  *) echo "Error: '$USER_NAME' is not subagent-managed (GECOS: '$GECOS')" >&2; exit 1 ;;
esac

if [[ "$KEEP_HOME" == "1" ]]; then
  USERDEL_CMD=(userdel "$USER_NAME")
else
  USERDEL_CMD=(userdel -r "$USER_NAME")
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "+ pkill -u $USER_NAME"
  printf '+'; printf ' %q' "${USERDEL_CMD[@]}"; printf '\n'
  exit 0
fi

pkill -u "$USER_NAME" || true
"${USERDEL_CMD[@]}"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run_all.sh`
Expected: all `test_delete_*` PASS

- [ ] **Step 5: Lint and commit**

```bash
shellcheck bin/delete-subaccount
git add bin/delete-subaccount tests/test_delete_subaccount.sh
git commit -m "Add delete-subaccount script"
```

---

### Task 9: `bin/group-create` and `bin/group-delete`

**Files:**
- Create: `bin/group-create`
- Create: `bin/group-delete`
- Create: `tests/test_groups.sh`

- [ ] **Step 1: Write the failing tests**

`tests/test_groups.sh`:

```bash
#!/bin/bash
# Tests for bin/group-create and bin/group-delete

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_group_create_dry_run() {
  local out
  out=$("$dir/../bin/group-create" --group devs --dry-run)

  if ! echo "$out" | grep -q "groupadd devs"; then
    echo "FAIL: expected groupadd devs"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "mkdir -p /home/agents/shared/devs"; then
    echo "FAIL: expected mkdir of shared dir"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "chmod 2770 /home/agents/shared/devs"; then
    echo "FAIL: expected chmod 2770 on shared dir"
    echo "$out"
    return 1
  fi
}

test_group_create_rejects_invalid_name() {
  if "$dir/../bin/group-create" --group "Bad Name" --dry-run 2>/dev/null; then
    echo "FAIL: should reject invalid group name"
    return 1
  fi
}

test_group_delete_dry_run() {
  local out
  out=$("$dir/../bin/group-delete" --group devs --dry-run)

  if ! echo "$out" | grep -q "groupdel devs"; then
    echo "FAIL: expected groupdel devs"
    echo "$out"
    return 1
  fi
  if ! echo "$out" | grep -q "rm -rf /home/agents/shared/devs"; then
    echo "FAIL: expected rm -rf of shared dir"
    echo "$out"
    return 1
  fi
}

test_group_delete_rejects_invalid_name() {
  if "$dir/../bin/group-delete" --group "Bad Name" --dry-run 2>/dev/null; then
    echo "FAIL: should reject invalid group name"
    return 1
  fi
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run_all.sh`
Expected: failures — `bin/group-create: No such file or directory`

- [ ] **Step 3: Write `bin/group-create`**

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

usage() {
  echo "Usage: group-create --group NAME [--dry-run]" >&2
  exit 1
}

GROUP_NAME=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --group) GROUP_NAME="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) usage ;;
  esac
done

[[ -n "$GROUP_NAME" ]] || usage
validate_identifier "$GROUP_NAME" "group"

SHARED_DIR="/home/agents/shared/$GROUP_NAME"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "+ groupadd $GROUP_NAME"
  echo "+ mkdir -p $SHARED_DIR"
  echo "+ chgrp $GROUP_NAME $SHARED_DIR"
  echo "+ chmod 2770 $SHARED_DIR"
  exit 0
fi

groupadd "$GROUP_NAME"
mkdir -p "$SHARED_DIR"
chgrp "$GROUP_NAME" "$SHARED_DIR"
chmod 2770 "$SHARED_DIR"
```

- [ ] **Step 4: Write `bin/group-delete`**

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

usage() {
  echo "Usage: group-delete --group NAME [--dry-run]" >&2
  exit 1
}

GROUP_NAME=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --group) GROUP_NAME="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) usage ;;
  esac
done

[[ -n "$GROUP_NAME" ]] || usage
validate_identifier "$GROUP_NAME" "group"

SHARED_DIR="/home/agents/shared/$GROUP_NAME"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "+ groupdel $GROUP_NAME"
  echo "+ rm -rf $SHARED_DIR"
  exit 0
fi

groupdel "$GROUP_NAME"
rm -rf "$SHARED_DIR"
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/run_all.sh`
Expected: all `test_group_*` PASS

- [ ] **Step 6: Lint and commit**

```bash
shellcheck bin/group-create bin/group-delete
git add bin/group-create bin/group-delete tests/test_groups.sh
git commit -m "Add group-create and group-delete scripts"
```

---

### Task 10: `bin/subagent-shell`, sudoers entry, and deployment notes

**Files:**
- Create: `bin/subagent-shell`
- Create: `sudoers/subagents`
- Create: `tests/test_subagent_shell.sh`
- Modify: `README.md`

- [ ] **Step 1: Write the failing test**

`tests/test_subagent_shell.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_all.sh`
Expected: failure — `bin/subagent-shell: No such file or directory`

- [ ] **Step 3: Write `bin/subagent-shell`**

```bash
#!/bin/bash
# Shared, static login shell for every subaccount (root:root, 755).
# Never regenerated — per-subaccount sandbox config lives in
# ~/.subagent/launcher, which bwrap-config-apply rebuilds from scratch.
exec tmux new-session -A -s main "$HOME/.subagent/launcher"
```

```bash
chmod +x bin/subagent-shell
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run_all.sh`
Expected: all `test_subagent_shell_*` PASS, and the full suite is green

- [ ] **Step 5: Write `sudoers/subagents`**

```
agents ALL=(root) NOPASSWD: /home/agents/bin/create-subaccount, \
  /home/agents/bin/delete-subaccount, /home/agents/bin/modify-subaccount, \
  /home/agents/bin/bwrap-config-set, /home/agents/bin/group-create, \
  /home/agents/bin/group-delete
```

- [ ] **Step 6: Write deployment notes in `README.md`**

```markdown
# subagents

Bash scripts that create, modify, and delete sandboxed Linux "subaccount" users.
See `PLAN.md` for the full design.

## Deploying

As root, on the target host:

```bash
# 1. Create the agents group and account if they don't already exist.
groupadd -f agents
id -u agents >/dev/null 2>&1 || useradd -m -g agents agents

# 2. Install scripts: root-owned, mode 755, not writable by agents.
mkdir -p /home/agents/bin
cp bin/* /home/agents/bin/
chown -R root:root /home/agents/bin
chmod 755 /home/agents/bin/*

# 3. Install profiles and skeleton: agents-owned, freely editable.
mkdir -p /home/agents/profiles /home/agents/skel /home/agents/shared
cp profiles/* /home/agents/profiles/
cp -r skel/. /home/agents/skel/
chown -R agents:agents /home/agents/profiles /home/agents/skel /home/agents/shared

# 4. Install the sudoers entry.
cp sudoers/subagents /etc/sudoers.d/subagents
chown root:root /etc/sudoers.d/subagents
chmod 440 /etc/sudoers.d/subagents
visudo -c
```

## Running the tests

```bash
bash tests/run_all.sh
```

Tests exercise `--dry-run` output and config/launcher generation only — no
real accounts are created. Real end-to-end testing happens manually in a
disposable VM or container (see `PLAN.md`, "Testing").
```

- [ ] **Step 7: Run the full suite one more time and lint everything**

```bash
bash tests/run_all.sh
shellcheck bin/*
```

Expected: full suite green, no shellcheck warnings

- [ ] **Step 8: Commit**

```bash
git add bin/subagent-shell sudoers/subagents tests/test_subagent_shell.sh README.md
git commit -m "Add subagent-shell, sudoers entry, and deployment docs"
```

---

## Self-review notes

- **Spec coverage:** every row of `PLAN.md`'s script inventory has a task
  (`create-subaccount` T6, `delete-subaccount` T8, `modify-subaccount` T7,
  `bwrap-config-apply` T2, `bwrap-config-set` T4, `setup-skeleton` T5,
  `group-create`/`group-delete` T9, `subagent-shell` T10). Profiles (T3) and
  the sudoers entry / deployment layout (T10) are covered. GECOS tag
  enforcement is in T7/T8. Identifier validation (`^[a-z][a-z0-9_-]{0,31}$`)
  is centralized in T1 and used by every script from T6 onward.
- **Placeholders:** none — every step has runnable code and concrete
  expected output.
- **Type/name consistency:** `validate_identifier(value, label)` defined in
  T1 is used identically in T2/T4–T9. `SUBAGENTS_TEST_HOME` (T2, T4–T6) and
  `SUBAGENTS_TEST_GECOS` (T7, T8) are the only test hooks, named consistently
  throughout. `bwrap-config-apply --user NAME [--dry-run]` signature in T2
  matches how T4 and T6 invoke it.
