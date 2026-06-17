# subagents — design plan

## Background

This project replaces the approach used in `bubbly-agents` (a single shared low-privilege
account, `agents`, running bubblewrap sandboxes for synthetic identities). That design
worked but had two recurring problems:

1. **No real per-identity login isolation.** All sandboxes run under the same host UID
   (`agents`), so they share a single tmux server / socket. A second login collides with
   whatever foreground session is already running instead of getting its own session.
2. **Overcomplicated identity layer.** Synthetic `/etc/passwd`/`/etc/group` injected via
   bwrap file descriptors, manual ulimit/cgroup wrangling, etc. — more machinery than
   necessary.

`bubbly-agents` is kept around only as a reference for comparing approaches; this is a
fresh project, starting from scratch.

## Goal

A small set of **bash scripts**, run from a low-privilege `agents` account, that create,
modify, and delete **real unprivileged Linux user accounts** ("subaccounts"), each
optionally sandboxed with `bwrap`. Sandboxing starts permissive and is tightened (or
loosened) later via dedicated scripts that regenerate a per-subaccount bwrap config from
scratch. Subaccounts can collaborate via shared group directories.

Priorities, in order: **simplicity, maintainability, clarity, security.**

## Why real accounts solve problem #1

Each subaccount gets its own real UID and home directory. tmux's client/server protocol
is a Unix-domain socket under `/tmp/tmux-<uid>/` — with a real per-subaccount UID, each
subaccount automatically gets its own tmux socket directory. Two logins (to the same or
different subaccounts) no longer collide, with no bwrap-side trickery required. bwrap's
namespace features (`--unshare-ipc`, `--unshare-pid`, etc.) don't interfere with this,
since tmux communication happens over a filesystem socket on the host side, outside the
sandbox.

## Directory layout

```
/home/agents/                          # the agents account's own home
  bin/                                  # privileged wrapper scripts (root-owned, see below)
    create-subaccount
    delete-subaccount
    modify-subaccount
    backup-subaccount         # tars a subaccount's home dir before deletion
    bwrap-config-apply        # regenerates a subaccount's launcher from its config
    find-free-subagent-id     # allocates paired UID/GID from the 50000-59999 range
    bwrap-config-set          # edits one config key, then re-applies
    setup-skeleton            # populates default home contents
    group-create
    group-delete
    subagent-shell            # shared static login shell for all subaccounts
    subagent                  # convenience entry point for the scripts above
  profiles/                              # bwrap config templates (agents-owned, editable)
    default.profile
    network-isolated.profile
    ...
  skel/                                   # default home contents for new subaccounts
  shared/<groupname>/                    # shared collaboration dirs (mode 2770)
  backups/<user>-<timestamp>.tar.gz      # home dir backups made before deletion

/home/<subuser>/                        # real Linux account, real home
  .subagent/
    config                              # KEY=VALUE bwrap config (agents:agents, 640)
    launcher                            # generated bwrap wrapper (agents:<subuser>, 750)
  ...                                    # normal home contents (skeleton-populated)
```

## Privilege model

**`/home/agents` directory permissions:** every subaccount's login shell is
`/home/agents/bin/subagent-shell`, so `/home/agents` itself needs the execute
("traverse") bit for "other" (`chmod o+x /home/agents`) — otherwise `su`/login for any
subaccount fails with "Permission denied" even though `subagent-shell` is `root:root
755`. This doesn't grant read access to `agents`'s own files; `/home/agents/bin`,
`profiles/`, `skel/`, `shared/`, and `backups/` each have their own restrictive
permissions.

**Critical security boundary:** the scripts in `/home/agents/bin/` that `agents` has
passwordless sudo for must be **owned by `root:root`, mode `755` — not writable by
`agents`**. If `agents` could edit a script it has NOPASSWD root sudo on, that's a direct
privilege escalation (edit the script, run it, get root). Updating these scripts requires
real root access (a deploy step), by design.

`/home/agents/profiles/*` and `/home/agents/skel/*` are owned by `agents` and freely
editable — they only ever influence a *subaccount's* sandbox config or initial home
contents, never root's command execution, so `agents` editing them is safe.

`.subagent/config` and `.subagent/launcher` in each subuser's home are written by the
root-run scripts. `config` is chowned `agents:agents` (640) — unreadable by the
subaccount. `launcher` is chowned `agents:<subuser>` (750) — the subaccount's own tmux
session execs it directly, so it must be readable/executable by the subaccount, but is
group-owned by the subaccount's own (single-member) group so only `agents`/root can
write it. Neither is directly writable by `agents` except through the wrapper scripts. A
subaccount can never loosen its own sandbox.

The **sticky bit** (`chmod +t`) is set on each subaccount's home directory by
`create-subaccount` after `setup-skeleton` chowns it to the subaccount. Without it, the
subaccount (who owns the home directory) could delete or rename the root-owned
`.subagent/` directory from inside the bind-mounted sandbox, replace it with their own
launcher, and escape bwrap. With the sticky bit, only the *owner of a directory entry*
can delete or rename it — root owns `.subagent/`, so the subaccount cannot touch it.

**sudoers entry** (`/etc/sudoers.d/subagents`):

```
agents ALL=(root) NOPASSWD: /home/agents/bin/create-subaccount, \
  /home/agents/bin/delete-subaccount, /home/agents/bin/modify-subaccount, \
  /home/agents/bin/bwrap-config-set, /home/agents/bin/group-create, \
  /home/agents/bin/group-delete, /home/agents/bin/exec-in
```

`bwrap-config-apply`, `setup-skeleton`, and `find-free-subagent-id` are internal —
called by the scripts above, not invoked directly by `agents`, but still live in the
root-owned `bin/` dir. `show-subaccount` requires no sudo — it is read-only and all
data it reads is accessible to `agents` directly.

**GECOS tag safeguard:** `create-subaccount` sets GECOS to `subagent-managed - <comment>`.
`delete-subaccount` reads GECOS via `getent passwd` and **aborts** if it doesn't start
with `subagent-managed -` — prevents accidentally deleting an unrelated system account.
(`:`, `,`, and `=` are all forbidden in the comment: they are `/etc/passwd` field
separators that `useradd -c`/`usermod -c` reject. `validate_comment` in `common.sh`
catches these proactively so the error surfaces before any system state is changed.)
`modify-subaccount` preserves the tag prefix when updating the comment.

**Input validation:** every root-run script uses `set -euo pipefail` and validates all
`--user`/`--group`/`--profile` arguments against a strict pattern
(`^[a-z][a-z0-9_-]{0,31}$`) before interpolating them into any command. This is the
primary injection-prevention measure for scripts that run as root via sudo.

## Login flow

`useradd -s` points every subaccount at one shared, static, root-owned script:

```bash
#!/bin/bash
# /home/agents/bin/subagent-shell  (root:root, 755 — identical for all subaccounts)
exec env SHELL=/bin/bash tmux new-session -A -s main "$HOME/.subagent/launcher"
```

`SHELL=/bin/bash` is required: tmux runs the given shell-command via its
`default-shell` option, which defaults to `$SHELL` — but a subaccount's `$SHELL` *is*
this script, so without the override tmux would re-exec `subagent-shell` (ignoring the
command) and try to attach to the "main" session it's still in the middle of creating,
exiting immediately.

Running as the subaccount's real UID gives it its own `/tmp/tmux-<uid>/` socket —
independent tmux sessions per subaccount, detach/reattach works normally, no collisions.
This script is never regenerated.

`.subagent/launcher` is the per-subaccount, regenerated `bwrap` invocation, run *inside*
the tmux pane.

## bwrap config format

`.subagent/config` is KEY=VALUE, parsed with `grep`/`cut`/`read` — **never sourced** —
so the file cannot execute code even if it were ever writable by something untrusted.

```
NETWORK=full
RO_BINDS=/usr /lib /lib64 /bin /sbin /etc/alternatives /etc/resolv.conf /etc/ssl /etc/ca-certificates /etc/passwd /etc/group
RW_BINDS=
EXTRA_RO_BINDS=
DEV_BINDS=
EXTRA_RW_BINDS=
TMPFS_MOUNTS=
ENV_SET=
ENV_UNSET=
```

- `NETWORK`: `full` (no `--unshare-net`) / `loopback` / `none`. `loopback` and `none`
  both add `--unshare-net`; `lo` remains available in the new net namespace either way,
  so "loopback" vs "none" is currently a documentation distinction (both isolate from
  the host network) — if a real difference is needed later it becomes a tightening
  knob, not a v1 requirement.
- `RO_BINDS`: space-separated host paths, each mounted `--ro-bind-try <path> <path>`
  (same source and destination path). Real UIDs mean `/etc/passwd` and `/etc/group` can
  be exposed as-is (no secrets there — `/etc/shadow` is never bound). `/etc/alternatives`
  is included because many `/usr/bin/*` commands (`awk`, `cc`, `editor`, `which`, ...)
  are `update-alternatives` symlinks pointing there; without it those symlinks are
  dangling inside the sandbox.
- `RW_BINDS`: space-separated `hostpath:sandboxpath` pairs, each `--bind-try <host>
  <sandbox>`. Used for shared group directories. `--bind-try` (rather than `--bind`)
  ensures a sandbox still launches even if the shared directory was later removed via
  `group-delete`, leaving a stale `RW_BINDS` entry.
- `EXTRA_RO_BINDS`: same syntax as `RO_BINDS`, for ad-hoc additions via
  `bwrap-config-set` without editing the base list.
- `DEV_BINDS`: space-separated host paths, each mounted `--dev-bind-try <path> <path>`.
  Like `RO_BINDS` but with device-file access (needed for GPU/DRI/sound devices).
- `EXTRA_RW_BINDS`: same syntax as `RW_BINDS` (colon-separated `hostpath:sandboxpath`
  pairs), for per-subaccount rw-bind additions without clobbering the profile's `RW_BINDS`.
- `TMPFS_MOUNTS`: space-separated paths, each mounted `--tmpfs <path>`. Used for
  additional volatile mounts beyond the hardcoded `/tmp` (e.g. `/run`, `/var/run`).
- `ENV_SET`: space-separated `NAME=VALUE` pairs, each emitted as `--setenv NAME VALUE`.
  Values may not contain spaces (space is the list delimiter). Useful for forcing `HOME`,
  `TMPDIR`, locale variables, etc. inside the sandbox.
- `ENV_UNSET`: space-separated environment variable names, each emitted as
  `--unsetenv NAME`. Strips leaking host variables (e.g. `DBUS_SESSION_BUS_ADDRESS`).
  Names must match `[A-Za-z_][A-Za-z0-9_]*`.

`bwrap-config-set` requires every bind/mount path (both sides of a colon pair for
`RW_BINDS`/`EXTRA_RW_BINDS`) to be absolute and free of `..` segments. `ENV_SET` and
`ENV_UNSET` values are validated as legal environment variable names instead.
`bwrap-config-apply`
iterates these space-separated lists with `set -f` (noglob) so a value containing `*`,
`?`, or `[...]` is passed through to `bwrap` literally rather than being glob-expanded
against the filesystem at apply-time.

`bwrap-config-apply` always rebuilds `.subagent/launcher` **de novo** from these fields —
never incrementally patched. The generated launcher is approximately:

```bash
exec bwrap \
  --unshare-ipc --unshare-pid --unshare-uts \
  [--unshare-net]                      # if NETWORK != full \
  --proc /proc --dev /dev --tmpfs /tmp \
  --bind "$HOME" "$HOME" \
  [--ro-bind-try <path> <path> ...]    # RO_BINDS \
  [--bind-try <host> <sandbox> ...]    # RW_BINDS \
  [--ro-bind-try <path> <path> ...]    # EXTRA_RO_BINDS \
  [--dev-bind-try <path> <path> ...]   # DEV_BINDS \
  [--bind-try <host> <sandbox> ...]    # EXTRA_RW_BINDS \
  [--tmpfs <path> ...]                 # TMPFS_MOUNTS \
  [--setenv NAME VALUE ...]            # ENV_SET \
  [--unsetenv NAME ...]                # ENV_UNSET \
  -- /bin/bash -l
```

`/bin/bash -l` is hardcoded rather than `"$SHELL"`: a subaccount's passwd shell is
`/home/agents/bin/subagent-shell`, an absolute host path that doesn't exist inside the
sandbox (`/home/agents` is never bound), so `exec bwrap ... -- "$SHELL"` would fail with
`bwrap: execvp /home/agents/bin/subagent-shell: No such file or directory`. `/bin/bash`
is always available since `/bin` is in every profile's `RO_BINDS`.

No `--unshare-user` and no synthetic `/etc/passwd` injection — real UIDs make that
unnecessary.

## Profiles

```
/home/agents/profiles/
  default.profile          # copied for new subaccounts unless --profile given
  network-isolated.profile # e.g. NETWORK=none
  ...
```

- `create-subaccount --user NAME [--profile NAME]` (default profile name: `default`)
  copies `/home/agents/profiles/<name>.profile` → `/home/<user>/.subagent/config`, then
  runs `bwrap-config-apply`.
- Profiles are plain template files, not live-linked: editing a profile later does not
  retroactively change existing subaccounts. Each subaccount owns its own copy, which is
  then tightened/loosened independently via `bwrap-config-set`.

## Shared group directories

`group-create devs`:
- `groupadd devs`
- `mkdir -p /home/agents/shared/devs`
- `chgrp devs /home/agents/shared/devs && chmod 2770 /home/agents/shared/devs`

Adding a subaccount to a group's collaboration space is two explicit steps (no hidden
magic):
1. `modify-subaccount --user alice --extra-groups devs` (→ `usermod -aG devs alice`)
2. `bwrap-config-set --user alice --set RW_BINDS="/home/agents/shared/devs:/home/alice/shared/devs"`
   (appending to any existing `RW_BINDS` value)

`group-delete devs` runs `groupdel devs` (fails if any user still has it as primary
group — standard `groupdel` behavior) and removes `/home/agents/shared/devs`.

## Script inventory

| Script | Does |
|---|---|
| `create-subaccount --user NAME [--profile NAME] [--extra-groups LIST] [--comment TEXT] [--dry-run]` | Holds a lock (`/var/lock/subagents-id-alloc.lock`) while allocating a paired UID/GID via `find-free-subagent-id`, then `groupadd -g <id> NAME`, `useradd -m -u <id> -g <id> -s /home/agents/bin/subagent-shell -c "subagent-managed - <comment>"`. Runs `setup-skeleton`, sets the sticky bit on `$HOME` (so the subaccount can't delete the root-owned `.subagent/`), then copies profile → `.subagent/config` and runs `bwrap-config-apply`. An ERR trap rolls back any partial state (orphan group or user) on failure. |
| `delete-subaccount --user NAME [--do-not-backup-home-dir] [--dry-run]` | Verifies GECOS tag (abort if missing), sends SIGTERM to the user's processes then SIGKILL after 1 s to ensure they are gone before `userdel -r`, runs `backup-subaccount` (unless `--do-not-backup-home-dir`), `userdel -r`. |
| `modify-subaccount --user NAME [--extra-groups LIST] [--remove-groups LIST] [--comment TEXT] [--dry-run]` | Thin `usermod`/`gpasswd` wrapper; preserves the `subagent-managed -` GECOS prefix. `--remove-groups` calls `gpasswd -d` per group and prints two warnings: one about the stale bind mount in the config, and one that the **running session still has group access** until terminated — with a `pkill -u` command to revoke immediately. |
| `bwrap-config-apply --user NAME` | Internal. Reads `.subagent/config`, regenerates `.subagent/launcher` from scratch. The generated launcher accepts an optional command via `$@`; when called with no args it starts `/bin/bash` (normal session); when called with args it passes them to bwrap as the init command (used by `exec-in --sandbox`). |
| `find-free-subagent-id` | Internal. Prints the lowest unused UID/GID in 50000-59999 (checking both `getent passwd` and `getent group`), or exits 1 if the range is exhausted. Called by `create-subaccount` and `group-create` while holding the allocation lock. |
| `bwrap-config-set --user NAME (--set KEY=VALUE \| --remove-bind KEY VALUE) [--dry-run]` | Edits one key in `.subagent/config`, then calls `bwrap-config-apply`. The tighten/loosen entry point. `--remove-bind` removes a single space-delimited entry from any list key (RO_BINDS, RW_BINDS, EXTRA_RO_BINDS, DEV_BINDS, EXTRA_RW_BINDS, TMPFS_MOUNTS, ENV_SET, ENV_UNSET). For `--set`, validates that NETWORK is one of `full`, `loopback`, or `none`; bind/mount paths must be absolute and free of `..`; ENV_SET/ENV_UNSET names must match `[A-Za-z_][A-Za-z0-9_]*`. |
| `setup-skeleton --user NAME [--skeleton PATH]` | Internal (called by `create-subaccount`). Copies `/home/agents/skel/` (or `--skeleton` dir) into `/home/<user>`, `chown -R` to the subuser. |
| `backup-subaccount --user NAME [--dry-run]` | Internal (called by `delete-subaccount`). `tar -czf`s the subaccount's home directory into `/home/agents/backups/<user>-<timestamp>.tar.gz`, owned by `agents:agents`. |
| `group-create --group NAME [--dry-run]` | `groupadd`, creates and permissions `/home/agents/shared/<group>`. |
| `group-delete --group NAME [--dry-run]` | `groupdel`, removes `/home/agents/shared/<group>`. |
| `subagent-shell` | Static, shared login shell for all subaccounts (see Login flow). Not a CLI tool — referenced by `useradd -s`. |
| `show-subaccount --user NAME` | Read-only inspection. Prints account info (uid/gid/comment), group memberships, bwrap config contents, and running processes (tmux sessions + bwrap PIDs). No sudo required — runs directly as `agents`. |
| `exec-in --user NAME [--sandbox] [--] CMD [ARGS...] [--dry-run]` | Run a command as the subaccount user. Default: `sudo -u NAME CMD` (host filesystem, no sandbox). With `--sandbox`: invokes the subaccount's launcher so CMD runs inside bwrap without a tmux session. |
| `subagent --help [SCRIPT] \| SCRIPT [ARGS...]` | Convenience entry point. `subagent --help` lists available scripts; `subagent --help SCRIPT` prints `--help` for that script only; `subagent SCRIPT ARGS` runs that script (via `sudo` for the scripts listed in the sudoers entry below, direct exec for `show-subaccount`). Each script can still be run standalone. |

## Testing

Every script supports `--dry-run`:
- Account ops (`useradd`/`usermod`/`userdel`/`groupadd`/`groupdel`): print the exact
  command that would run.
- `bwrap-config-apply` / `bwrap-config-set`: print a diff of the config file and the
  resulting launcher script, without writing either.

Every script with a `usage()` also supports `-h`/`--help`, which prints the usage line,
a short description, and an `Options:` list to stdout and exits 0 (invalid arguments
still go to `usage()` on stderr with exit 1). See `tests/test_help.sh`.

`subagent` dispatches to the other scripts, using `sudo` for the ones that require root;
`SUBAGENTS_TEST_SUDO_CMD=""` skips the `sudo` prefix for testing. See
`tests/test_subagent.sh`.

`delete-subaccount` backs up the home directory via `backup-subaccount` by default
(skip with `--do-not-backup-home-dir`). `backup-subaccount` honors
`SUBAGENTS_TEST_HOME`, `SUBAGENTS_TEST_BACKUP_DIR`, and `SUBAGENTS_TEST_TIMESTAMP` for
testing. See `tests/test_backup_subaccount.sh`.

Real end-to-end testing happens manually in a disposable VM or container — no automated
test suite for the privileged paths in v1 (faking `useradd`/`sudo` meaningfully is a
separate large project and not worth the complexity here).

## Out of scope for v1

- Resource limits (ulimits, cgroup memory/CPU caps) — `bubbly-agents` had these; can be
  added later as additional `.subagent/config` fields and launcher flags without
  changing the overall design.
- seccomp syscall filtering.
- Any TUI/CLI wrapper beyond the individual bash scripts.
