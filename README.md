# subagents

Bash scripts that create, modify, and delete sandboxed Linux "subaccount" users.
See `PLAN.md` for the full design.

## Deploying

As root, on the target host:

```bash
# 1. Create the agents group and account if they don't already exist.
groupadd -f agents
id -u agents >/dev/null 2>&1 || useradd -m -g agents agents

# `useradd -m` creates /home/agents as mode 750 (agents:agents), which blocks
# *other* users from traversing into it at all. Every subaccount's login shell
# is /home/agents/bin/subagent-shell, so /home/agents itself needs the execute
# (traverse) bit for "other" -- without it, su/login fails with "Permission
# denied" even though subagent-shell itself is root:root 755. This does not
# grant read access to agents' own files; subdirectories keep their own perms.
chmod o+x /home/agents

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
