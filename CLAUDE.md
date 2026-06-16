# subagents

## What this project is

A small set of **bash scripts**, run from a low-privilege `agents` account, that create,
modify, and delete **real unprivileged Linux user accounts** ("subaccounts"), each
optionally sandboxed with `bwrap`. Sandboxing starts permissive and is tightened (or
loosened) later via scripts that regenerate a per-subaccount bwrap config from scratch.
Subaccounts can collaborate via shared group directories.

Priorities, in order: **simplicity, maintainability, clarity, security.**

This is a fresh project with no external dependencies on, or references to, any other
repo. Full design rationale and decisions are in [`PLAN.md`](PLAN.md) — read that first
for any design or architecture question.

## Status

Implemented (see `PLAN.md` for design rationale, `README.md` for deployment, and
`tests/` for the test suite — run via `bash tests/run_all.sh`).

## Key conventions (see PLAN.md for full detail)

- Every subaccount is a real `useradd`-created Linux user, GECOS-tagged
  `subagent-managed - <comment>`. `delete-subaccount` refuses to run unless this tag is
  present. (Not a `:` — `useradd -c`/`usermod -c` reject `:`, `,`, `=` in GECOS.)
- Privileged scripts live in `/home/agents/bin/`, are **root-owned, mode 755, not
  writable by `agents`** — `agents` has passwordless sudo for exactly these scripts.
  This ownership boundary is the core security property of the whole design; never
  propose making these scripts agents-writable.
- `.subagent/config` (per-subaccount bwrap config) is **KEY=VALUE, parsed with
  grep/cut/read — never `source`d**. Keys: `NETWORK`, `RO_BINDS`, `RW_BINDS`,
  `EXTRA_RO_BINDS`.
- `.subagent/launcher` (generated bwrap invocation) is always rebuilt **de novo** from
  `.subagent/config` by `bwrap-config-apply` — never incrementally patched.
- tmux runs *outside* bwrap (via the shared static `subagent-shell` login script), so
  each subaccount gets its own `/tmp/tmux-<uid>/` socket.
- Every script supports `--dry-run` (prints commands / config diffs, makes no changes).
- All user-supplied identifiers (`--user`, `--group`, `--profile`) are validated against
  `^[a-z][a-z0-9_-]{0,31}$` before use in any root-run script. Scripts use
  `set -euo pipefail`.

## Workflow

Use `superpowers:writing-plans` to turn `PLAN.md` into an implementation plan when ready
to start coding.
