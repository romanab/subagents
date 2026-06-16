# Paired UID/GID allocation for subaccounts — design

## Background

`create-subaccount` currently calls `useradd -m` without `-u`/`-g`, so the system
assigns the next available UID per the normal `UID_MIN`/`UID_MAX` rules (1000–60000),
and (depending on `USERGROUPS_ENAB`) a same-named primary group whose GID may or may
not match the UID. `group-create` similarly calls plain `groupadd`, drawing from the
same GID pool used by everything else on the host (including human users).

This means:
- A subaccount's UID and primary GID can drift apart over time as other accounts/groups
  are created and deleted on the host.
- Subagent-managed identities are not visually distinguishable from ordinary human
  user accounts by ID alone.
- There's no reuse strategy for IDs freed by `delete-subaccount`/`group-delete` — gaps
  just accumulate in the normal pool.

## Goal

Give every subagent-managed identity (subaccount primary user+group, and shared
collaboration groups from `group-create`) a UID/GID drawn from a single reserved
range, with subaccount UID == primary GID, allocated by filling the lowest free
number first so gaps left by deletions get reused.

## Reserved range

**50000–59999**, a sub-range of the existing `UID_MAX`/`GID_MAX` = 60000 ceiling in
`/etc/login.defs`. No `login.defs` changes needed. This range is shared by:
- Subaccount UID + primary GID pairs (`create-subaccount`)
- Shared collaboration group GIDs (`group-create`)

Using one shared pool for both means a number handed out as a shared group's GID will
never later collide with a subaccount's UID/GID, and vice versa.

## Allocator: `find-free-subagent-id` script

A new internal script, `bin/find-free-subagent-id` (root-owned, mode 755, alongside
`bwrap-config-apply`/`setup-skeleton` — not added to sudoers, since its only callers,
`create-subaccount` and `group-create`, already run as root via sudo):

- Loops `N` from 50000 to 59999, checking `getent passwd "$N" >/dev/null` and
  `getent group "$N" >/dev/null`.
- On success: prints the first `N` where both lookups fail (not found) to stdout,
  exits 0.
- On exhaustion (no free `N` in range): prints an error to stderr, exits 1.

Pure read-only query — safe to call in `--dry-run`, and independently testable.

## `create-subaccount` changes

1. `ID=$("$SCRIPT_DIR/find-free-subagent-id")`
2. `groupadd -g "$ID" "$USER_NAME"` — explicitly create the primary group first
3. `useradd -m -u "$ID" -g "$ID" -s /home/agents/bin/subagent-shell -c "$GECOS" ...`
   (adds explicit `-u`/`-g` to the existing useradd invocation; `-G`/extra groups
   unchanged)

`--dry-run` resolves `ID` via `find-free-subagent-id` (live, read-only lookup) and
prints the resulting `groupadd -g $ID $USER_NAME` and `useradd ... -u $ID -g $ID ...`
commands, making no changes — consistent with how dry-run already shows real paths.
If `find-free-subagent-id` exits 1 (range exhausted), `create-subaccount` aborts
immediately with that error, even in `--dry-run`.

## `group-create` changes

1. `ID=$("$SCRIPT_DIR/find-free-subagent-id")`
2. `groupadd -g "$ID" "$GROUP_NAME"`

`--dry-run` resolves and prints `ID` the same way, aborting on exhaustion as above.

## `delete-subaccount` / `group-delete` — no changes needed

- `userdel -r` already removes a user's primary group when it's a same-named group
  with no other members, so deleting a subaccount frees both its UID and its GID
  (the same number) back into the pool.
- `group-delete` already runs `groupdel`, freeing that GID back into the pool.

Gap reuse therefore falls out of the allocator naturally: it always returns the
lowest free number, so IDs freed by deletions are the first to be reused.

## Edge cases

- **Range exhaustion** (10000 IDs all in use): `find-free-subagent-id` exits 1 with
  a clear error; `create-subaccount`/`group-create` abort before making any changes.
- **`--keep-home` deletions**: `userdel` (without `-r`) does not remove the group, so
  the ID stays reserved until the group is removed manually — acceptable, matches
  existing `--keep-home` semantics of leaving the account mostly intact.

## Testing

- New `tests/test_find_free_subagent_id.sh`: running the script returns a number
  matching `5[0-9]{4}` and exit 0 (where feasible, asserts it returns 50000 when
  nothing in the range is allocated on the test host).
- Updated `test_create_subaccount.sh` / `test_groups.sh` dry-run assertions to expect
  `groupadd -g <ID> ...` and `useradd ... -u <ID> -g <ID> ...` with `<ID>` matching
  `5[0-9]{4}` rather than the previous bare `useradd ... NAME` form.
