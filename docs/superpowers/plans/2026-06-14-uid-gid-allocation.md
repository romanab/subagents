# Paired UID/GID Allocation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every subagent-managed identity (subaccount UID + primary GID, and
shared collaboration group GIDs) a paired ID drawn from the reserved range
50000-59999, allocated lowest-free-first so gaps from deletions get reused.

**Architecture:** A new internal script, `bin/find-free-subagent-id`, scans
`getent passwd`/`getent group` for the lowest unused ID in 50000-59999 and prints it
(or exits 1 if the range is exhausted). `create-subaccount` and `group-create` call it
and pass the result to `groupadd -g`/`useradd -u -g` instead of letting those tools
pick IDs themselves.

**Tech Stack:** bash (`set -euo pipefail`), `getent`, `useradd`/`groupadd`,
`shellcheck`, plain bash test scripts run via `tests/run_all.sh`.

Spec: `docs/superpowers/specs/2026-06-14-uid-gid-allocation-design.md`

---

## Conventions

- Test files define `dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` and call
  scripts via `"$dir/../bin/<script>"`.
- After writing/editing each script, run `shellcheck bin/<script>` and fix warnings
  before committing.
- Run the full suite with `tests/run_all.sh` before each commit.

---

### Task 1: `bin/find-free-subagent-id`

**Files:**
- Create: `bin/find-free-subagent-id`
- Create: `tests/test_find_free_subagent_id.sh`

- [ ] **Step 1: Write the failing test**

`tests/test_find_free_subagent_id.sh`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_find_free_subagent_id.sh; tests/run_all.sh 2>/dev/null | grep find_free`

Expected: `tests/run_all.sh` reports `FAIL: test_find_free_subagent_id_returns_id_in_range`
and `FAIL: test_find_free_subagent_id_not_in_use` (script doesn't exist yet, so `$out`
is empty and neither check passes).

- [ ] **Step 3: Write `bin/find-free-subagent-id`**

```bash
#!/bin/bash
# Prints the lowest UID/GID in 50000-59999 not already in use as a UID or GID.
# Exits 1 with an error on stderr if the entire range is in use.
set -euo pipefail

RANGE_MIN=50000
RANGE_MAX=59999

for ((id = RANGE_MIN; id <= RANGE_MAX; id++)); do
  if ! getent passwd "$id" >/dev/null && ! getent group "$id" >/dev/null; then
    echo "$id"
    exit 0
  fi
done

echo "Error: no free UID/GID in range $RANGE_MIN-$RANGE_MAX" >&2
exit 1
```

```bash
chmod +x bin/find-free-subagent-id
```

- [ ] **Step 4: Lint and run the test to verify it passes**

Run: `shellcheck bin/find-free-subagent-id && tests/run_all.sh 2>/dev/null | grep find_free`

Expected:
```
PASS: test_find_free_subagent_id_not_in_use
PASS: test_find_free_subagent_id_returns_id_in_range
```

- [ ] **Step 5: Commit**

```bash
git add bin/find-free-subagent-id tests/test_find_free_subagent_id.sh
git commit -m "Add find-free-subagent-id allocator script"
```

---

### Task 2: `create-subaccount` uses paired UID/GID

**Files:**
- Modify: `bin/create-subaccount`
- Modify: `tests/test_create_subaccount.sh`

- [ ] **Step 1: Update the failing tests**

Replace `test_create_dry_run_prints_useradd_with_gecos` and add a new pairing test in
`tests/test_create_subaccount.sh`. Replace the whole file with:

```bash
#!/bin/bash
# Tests for bin/create-subaccount

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_create_dry_run_prints_useradd_with_gecos() {
  local out
  out=$("$dir/../bin/create-subaccount" --user alice --comment "test bot" --dry-run)

  if ! echo "$out" | grep -qE "useradd -m -u 5[0-9]{4} -g 5[0-9]{4} -s /home/agents/bin/subagent-shell -c 'subagent-managed: test bot' alice"; then
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
  if [[ "$group_id" != "$useradd_uid" || "$group_id" != "$useradd_gid" ]]; then
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
```

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run: `tests/run_all.sh 2>/dev/null | grep -E "create_dry_run_prints_useradd|create_dry_run_prints_groupadd"`

Expected:
```
FAIL: test_create_dry_run_prints_groupadd_with_matching_id
FAIL: test_create_dry_run_prints_useradd_with_gecos
```
(current script prints `useradd -m -s ... alice` with no `-u`/`-g`/`groupadd` line)

- [ ] **Step 3: Update `bin/create-subaccount`**

Replace the body from `GECOS="subagent-managed: $COMMENT"` onward (lines 40-76) with:

```bash
GECOS="subagent-managed: $COMMENT"
PROFILE_FILE="/home/agents/profiles/$PROFILE.profile"
HOME_DIR="${SUBAGENTS_TEST_HOME:-/home/$USER_NAME}"
ID=$("$SCRIPT_DIR/find-free-subagent-id")

USERADD_CMD=(useradd -m -u "$ID" -g "$ID" -s /home/agents/bin/subagent-shell -c "$GECOS")
if [[ -n "$EXTRA_GROUPS" ]]; then
  USERADD_CMD+=(-G "$EXTRA_GROUPS")
fi
USERADD_CMD+=("$USER_NAME")

if [[ "$DRY_RUN" == "1" ]]; then
  echo "+ groupadd -g $ID $USER_NAME"
  printf "+ useradd -m -u %s -g %s -s /home/agents/bin/subagent-shell -c '%s'" "$ID" "$ID" "$GECOS"
  if [[ -n "$EXTRA_GROUPS" ]]; then
    printf ' -G %s' "$EXTRA_GROUPS"
  fi
  printf ' %s\n' "$USER_NAME"
  echo "+ mkdir -p $HOME_DIR/.subagent"
  echo "+ cp $PROFILE_FILE $HOME_DIR/.subagent/config"
  echo "+ chown agents:agents $HOME_DIR/.subagent/config"
  echo "+ chmod 640 $HOME_DIR/.subagent/config"
  echo "+ $SCRIPT_DIR/bwrap-config-apply --user $USER_NAME"
  echo "+ $SCRIPT_DIR/setup-skeleton --user $USER_NAME"
  exit 0
fi

[[ -f "$PROFILE_FILE" ]] || { echo "Error: profile '$PROFILE' not found at $PROFILE_FILE" >&2; exit 1; }

groupadd -g "$ID" "$USER_NAME"
"${USERADD_CMD[@]}"

mkdir -p "$HOME_DIR/.subagent"
cp "$PROFILE_FILE" "$HOME_DIR/.subagent/config"
chown agents:agents "$HOME_DIR/.subagent/config"
chmod 640 "$HOME_DIR/.subagent/config"

"$SCRIPT_DIR/bwrap-config-apply" --user "$USER_NAME"
"$SCRIPT_DIR/setup-skeleton" --user "$USER_NAME"
```

- [ ] **Step 4: Lint and run the tests to verify they pass**

Run: `shellcheck bin/create-subaccount && tests/run_all.sh 2>/dev/null | grep create_`

Expected: all `test_create_*` lines show `PASS`.

- [ ] **Step 5: Commit**

```bash
git add bin/create-subaccount tests/test_create_subaccount.sh
git commit -m "Allocate paired UID/GID for new subaccounts"
```

---

### Task 3: `group-create` uses the reserved GID range

**Files:**
- Modify: `bin/group-create`
- Modify: `tests/test_groups.sh`

- [ ] **Step 1: Update the failing test**

In `tests/test_groups.sh`, replace `test_group_create_dry_run` with:

```bash
test_group_create_dry_run() {
  local out
  out=$("$dir/../bin/group-create" --group devs --dry-run)

  if ! echo "$out" | grep -qE "groupadd -g 5[0-9]{4} devs"; then
    echo "FAIL: expected groupadd -g <ID> devs with ID in 50000-59999"
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
```

(Leave `test_group_create_rejects_invalid_name`, `test_group_delete_dry_run`, and
`test_group_delete_rejects_invalid_name` unchanged.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `tests/run_all.sh 2>/dev/null | grep test_group_create_dry_run`

Expected: `FAIL: test_group_create_dry_run` (current script prints `groupadd devs` with
no `-g <ID>`).

- [ ] **Step 3: Update `bin/group-create`**

Replace lines 26-39 (from `SHARED_DIR="/home/agents/shared/$GROUP_NAME"` to the end)
with:

```bash
ID=$("$SCRIPT_DIR/find-free-subagent-id")
SHARED_DIR="/home/agents/shared/$GROUP_NAME"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "+ groupadd -g $ID $GROUP_NAME"
  echo "+ mkdir -p $SHARED_DIR"
  echo "+ chgrp $GROUP_NAME $SHARED_DIR"
  echo "+ chmod 2770 $SHARED_DIR"
  exit 0
fi

groupadd -g "$ID" "$GROUP_NAME"
mkdir -p "$SHARED_DIR"
chgrp "$GROUP_NAME" "$SHARED_DIR"
chmod 2770 "$SHARED_DIR"
```

- [ ] **Step 4: Lint and run the tests to verify they pass**

Run: `shellcheck bin/group-create && tests/run_all.sh 2>/dev/null | grep group_`

Expected: all `test_group_*` lines show `PASS`.

- [ ] **Step 5: Commit**

```bash
git add bin/group-create tests/test_groups.sh
git commit -m "Allocate group GIDs from the reserved subagent range"
```

---

### Task 4: Update `PLAN.md` script inventory

**Files:**
- Modify: `PLAN.md`

- [ ] **Step 1: Add `find-free-subagent-id` to the script inventory table**

In `PLAN.md`, in the "Script inventory" table (around line 207-212), add a row after
`bwrap-config-apply`'s row:

```markdown
| `find-free-subagent-id` | Internal. Prints the lowest unused UID/GID in 50000-59999 (checking both `getent passwd` and `getent group`), or exits 1 if the range is exhausted. Called by `create-subaccount` and `group-create`. |
```

Also update the `create-subaccount` row (line 204) to reflect the new `-u`/`-g`
arguments — change:

```markdown
| `create-subaccount --user NAME [--profile NAME] [--extra-groups LIST] [--comment TEXT] [--dry-run]` | `useradd -m -s /home/agents/bin/subagent-shell -c "subagent-managed: <comment>"`, copies profile → `.subagent/config`, runs `bwrap-config-apply`, runs `setup-skeleton`. |
```

to:

```markdown
| `create-subaccount --user NAME [--profile NAME] [--extra-groups LIST] [--comment TEXT] [--dry-run]` | Allocates a paired UID/GID via `find-free-subagent-id`, `groupadd -g <id> NAME`, `useradd -m -u <id> -g <id> -s /home/agents/bin/subagent-shell -c "subagent-managed: <comment>"`, copies profile → `.subagent/config`, runs `bwrap-config-apply`, runs `setup-skeleton`. |
```

Also add a short note to the "Directory layout" script list (around line 47-52),
after `bwrap-config-apply`:

```
    find-free-subagent-id     # allocates paired UID/GID from the 50000-59999 range
```

- [ ] **Step 2: Run the full suite one more time**

Run: `tests/run_all.sh 2>/dev/null | grep -c PASS` and `tests/run_all.sh 2>/dev/null | grep FAIL`

Expected: a count of passing tests, and no `FAIL` lines.

- [ ] **Step 3: Commit**

```bash
git add PLAN.md
git commit -m "Document find-free-subagent-id in PLAN.md script inventory"
```
