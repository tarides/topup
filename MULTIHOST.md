# Multi-host topup

A single `topup` MCP server can drive any number of remote OCaml
toplevels in addition to its in-process one. Each call to `eval`,
`env`, `lookup`, `load`, `reset`, or `cancel` takes an optional
`host` argument; omit it (or pass `"local"`) to hit the in-process
session, pass any other name to route through an SSH-tunneled Unix
socket to a `topup --socket` daemon on that machine.

This document covers the user-facing path: how to set a remote up,
how to drive it day to day, and what to watch out for. For the
internals (registry persistence, socket-path conventions,
implementation notes), see the "Multi-host routing" section in
[CLAUDE.md](CLAUDE.md).

## Prerequisites

For each remote host you want to use:

- **Passwordless SSH** from your local machine to the remote (e.g.
  `ssh-copy-id <host>` once). The local `topup` spawns
  `ssh <host> ...` non-interactively; any prompt blocks the
  session.
- **`topup` on the remote's non-interactive `PATH`**. The local
  side runs `ssh <host> topup --socket <path>`, which uses the
  shell's default non-interactive `PATH` (typically
  `/usr/local/bin:/usr/bin:/bin`). Two ways to satisfy this:
  - Install topup somewhere on the system PATH (e.g.
    `sudo ln -s ~/.opam/<switch>/bin/topup /usr/local/bin/topup`).
  - Build/install it under `~/.local/bin/` *and* ensure that
    directory is on the non-interactive PATH (most distros don't
    add it by default).
- **A compatible OCaml**. The remote's `topup` must build against
  the same compiler family as the local one. As of v0.1.0 that
  means OCaml ≥ 5.3. A mismatch shows up as a compile error
  during `opam install`, not a runtime issue.

The remote socket directory (`~/.topup/sockets/`) is created on
demand by the local side's SSH wrapper — you don't need to
pre-create it.

## Quick start

Once the local MCP server is running (e.g. via Claude Code), one
call per host brings the remote up:

```
mcp__topup__start_session { host: "myhost" }
```

This opens the SSH tunnel and performs the MCP `initialize`
handshake against the remote daemon. It is idempotent — a second
call against a live tunnel is a no-op. On success the response
includes the host name and the remote socket path.

After that, every `eval` / `env` / `lookup` / `load` / `reset` /
`cancel` accepts an optional `host`:

```
mcp__topup__eval { host: "myhost", source: "let n = Domain.recommended_domain_count ();;" }
mcp__topup__eval { host: "myhost", source: "n;;" }
mcp__topup__env  { host: "myhost" }
```

State persists per host — the binding `n` lives on the remote
toplevel and is not visible to bare (local) calls.

To list what's currently registered, look at the `instructions`
block in the `initialize` response — it's rebuilt on every
handshake from the in-process registry and lists each known host
with its connection state and any metadata.

## `/caml --host=<name>` (slash command)

If you use the `/caml` skill, append `--host=<name>` to route a
single call:

```
/caml --host=myhost let xs = List.init 1_000 Fun.id;;
/caml --host=myhost #env
/caml --host=myhost #reset
```

Bare `/caml <src>` deliberately stays local — there is no sticky
default. To make calls to a single remote the norm without typing
`--host=` every time, ship a per-host slash command (next
section).

## Per-host slash command

If you talk to one remote often, a dedicated `/myhost`-style
slash command is cleaner than `--host=<name>` on every call.
Create `.claude/skills/<host>/SKILL.md` with a frontmatter like:

```yaml
---
name: myhost
description: Evaluate OCaml on the `myhost` remote toplevel.
---
```

…and a body that mirrors the `/caml` skill's directive table, but
hardwires `host: "<your-host>"` into every underlying
`mcp__topup__*` call (and rejects any `--host=<other>` override —
the point of the dedicated skill is one host per command). Use the
`/caml` skill at `.claude/skills/caml/SKILL.md` as a template: the
directive table is identical, only the routing changes.

## Lifecycle

| Tool | Purpose |
|------|---------|
| `start_session { host }` | Open the SSH tunnel and register the host. Idempotent. |
| `restart_session { host }` | Tear down and re-spawn the tunnel. Use when wedged; for a fresh OCaml environment on the remote, use `reset` instead. |
| `update_host { host, description?, os? }` | Set the metadata surfaced in the `instructions` block at the next `initialize`. |
| `reset { host }` | Discard the remote toplevel's environment. Keeps the tunnel up. |
| `cancel { host }` | Interrupt the remote's running evaluation. Bare `cancel` (no host) cancels the local session only — there is no broadcast. |

The registry persists *metadata* (description, OS, last-seen,
pinned socket path) to `~/.topup/hosts.json` so descriptions
survive across `topup` server restarts. Live SSH tunnels do not
persist — restarted servers come up cold and you must
`start_session` again. Disable persistence by setting
`TOPUP_HOSTS_FILE=off`.

## Limitations

These are deliberate v1 cuts; see `backlog.md` for the rationale:

- **One call at a time per server.** The MCP server processes
  `tools/call` sequentially, so per-host serialisation is implicit
  but parallel fan-out across hosts is not yet available.
- **No auto-reconnect.** If a tunnel dies (network blip, remote
  reboot), the next call returns a connect error. Call
  `restart_session { host }` to bring it back up.
- **No broadcast cancel.** `cancel { host: X }` cancels host X
  only. Bare `cancel` cancels the local session.
- **Phrase log and spill files are remote-side.** A routed eval
  whose `value_repr` / `stdout` / `stderr` overflows writes its
  spill file under `$HOME/.topup/spill/` *on the remote*. The
  local agent can't read it directly; copy it back over scp if
  needed.

## Troubleshooting

- `host not registered: <host>` — call `start_session { host:
  "<host>" }` first. This is intentional; the slash-command skills
  do not auto-issue it.
- `phase: connect` error from `start_session` — common causes:
  passwordless SSH not set up; `topup` not on the remote's
  non-interactive PATH (see Prerequisites); OCaml version
  mismatch.
- "Socket already in use" on `start_session` — usually means an
  orphaned `topup --socket` daemon survived a prior run. Should
  not happen with current cleanup (PR #4), but if you suspect it,
  `ssh <host> 'pkill -f "topup --socket"; rm -f
  ~/.topup/sockets/topup.sock'` resets the slate.

## See also

- `CLAUDE.md` — operational and internal notes (registry
  persistence schema, SSH-spawn details, test hooks).
- `DESIGN.md` — the "Distributed sessions" subsection of the
  phase-2 roadmap.
- `backlog.md` — open items, including parallel cross-host
  dispatch, broadcast cancel, and auto-reconnect.
