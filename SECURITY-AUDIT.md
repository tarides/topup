# Security audit — topup

Scope: the trust boundaries `topup` crosses on a client's behalf — SSH
spawning, subprocess forks, Unix-socket listeners, in-band file transfer,
and the remote→local back-channel. `topup`'s headline capability is
**arbitrary OCaml evaluation**, so the MCP client (the LLM/operator) is
inherently trusted to run code; "can it execute code?" is not a finding.
What matters is whether a *boundary* can be turned against the operator.

Four threat models, all in scope:

1. **Prompt-injection of tool arguments** — the trusted LLM is steered by
   untrusted content into calling a tool with a hostile argument.
2. **Untrusted/compromised remote** — `start_session` to a host that may
   be malicious.
3. **Shared multi-user host** — other OS users are adversaries.
4. **DoS / robustness** — resource exhaustion by a misbehaving peer.

Status: all findings below are **remediated** on this branch (with tests).
Severities reflect post-triage assessment; two subagent claims were
downgraded and one proposed exploit payload was corrected (see F1).

---

## Findings

### F1 — SSH argument injection via `host` — HIGH (fixed)
**Where:** `lib/mcp/proxy.ml` `spawn_ssh`.
**Threat models:** 1 (prompt-injection), 2.

`host` was passed to `ssh` as a bare argv token with no validation and no
`--` terminator. A value beginning with `-` (e.g.
`-oProxyCommand=touch /tmp/pwned`) is parsed by ssh as an option and runs
a command on the **local** machine via `/bin/sh`. The realistic delivery
path is a prompt-injected `start_session` / `--remote` argument.

> Correction: a payload like `"user@host -o ProxyCommand=…"` does **not**
> work — it is a single argv token ssh treats as a literal hostname. The
> exploitable shape is a token that *is itself* an option (leading `-`).

**Fix:** `Proxy.validate_host` accepts only `[A-Za-z0-9._@-]+` and rejects
a leading `-`; `validate_remote_socket` requires an absolute, NUL/newline-
free path. Enforced in `spawn_ssh` and again up-front in
`Remote_host.start` (so the error surfaces uniformly, including on the
test-hook path). A `--` is inserted before `host` in the ssh argv as
defense-in-depth.

### F2 — Back-channel arbitrary local file R/W — MEDIUM (fixed)
**Where:** `lib/mcp/blob.ml` `dispatch`, invoked by `Remote_host.on_request`.
**Threat models:** 2.

`_send_blob`/`_recv_blob` accepted any path (only `~` expansion). Over the
back-channel these are driven by the **remote** peer (and by remote-eval'd
code calling `Topup.read_back`/`write_back`), so a compromised remote could
read/write any local file the operator can — `~/.ssh/id_rsa`, etc. The
forward direction (the operator's own `push_file`/`pull_file`, and
`read_back`/`write_back` on local/in-process evals) is operator-initiated
and remains unconfined by design.

**Fix:** `Blob.dispatch ?confine_root` reinterprets the request under a root,
lexically resolves `..`, rejects escapes, and `realpath`-checks an existing
parent against symlink escapes. Only the back-channel call site passes a
root (`TOPUP_BACKCHANNEL_ROOT`, default `$HOME/.topup/back`; `off` disables
for trusted-remote setups). This also bounds the path echoed back in
error/result messages (subsumes the LOW "path disclosure" finding).

### F3 — Unbounded message read → OOM — MEDIUM (fixed)
**Where:** `lib/mcp/rpc.ml` `read_message`.
**Threat models:** 2, 4.

`input_line` read until newline with no cap; a peer streaming one huge line
exhausts memory.

**Fix:** a bounded reader capped at `TOPUP_MAX_MESSAGE_BYTES` (default
64 MiB — above a 16 MiB blob's ~21.8 MiB base64 frame) raises
`Message_too_large` instead of allocating without bound. The `Channel`
reader treats it as EOF and tears the connection down.

### F4 — Notification thread explosion / unbounded queues — MEDIUM (fixed)
**Where:** `lib/mcp/channel.ml`.
**Threat models:** 2, 4.

A thread was spawned per inbound notification; the work queue and pending
table were unbounded. A notification/request flood from a malicious remote
exhausts threads/memory.

**Fix:** concurrent notification threads capped (`max_notif_threads`, excess
dropped — `notifications/cancelled` still rides its own thread when under
the cap); inbound work queue bounded (`max_work_queue`, excess dropped);
pending table bounded (`max_pending`, `request` fails cleanly when full).

### F5 — Unix socket hardening — MEDIUM (fixed)
**Where:** `lib/mcp/server.ml` `serve_unix` / `prepare_socket_path`.
**Threat models:** 3.

The listening socket relied solely on the `0o700` parent dir for access
control (fine for the `~/.topup/sockets` default, exposed if pinned under
`/tmp`); `prepare_socket_path` used `stat` (follows symlinks) and unlinked
whatever it found.

**Fix:** the socket is bound under `umask 0o177` and `chmod`ed to `0o600`
(AF_UNIX connect needs write permission, so this restricts connections to
the owner). `prepare_socket_path` uses `lstat` and refuses to unlink a
**symlink** (the attack), while still cleaning up a stale regular file or
dead socket left by a crash.

### F6 — World-readable metadata / temp files — LOW (fixed)
**Where:** `host_registry.ml`, `session_pool.ml`, `blob.ml`, `tools.ml`,
`topup_runtime.ml`.
**Threat models:** 3.

`hosts.json`/`sessions.json` and transfer temp files were created `0o644`.
On a shared host, host names (PII per the repo's own rule) were readable by
other users.

**Fix:** all switched to `0o600` via `open_out_gen`.

### F7 — `compile_to_binary` library-name sexp injection — LOW (fixed)
**Where:** `lib/topup/promote.ml` `synthesise_dune`.
**Threat models:** 1.

Library names were interpolated verbatim into the generated `dune`
S-expression.

**Fix:** `validate_libraries` restricts each to the findlib charset
`[A-Za-z0-9._-]+` before the dune file is written.

---

## Audited and found safe (no change)

- **Checkpoint/restore labels** (`session.ml`): strict charset, no leading
  `.`, no `..`, validated in `Session` not just at the MCP edge.
- **`#use` / prewarm replay**: paths embedded via `%S`, no phrase injection;
  the directive-skip guard prevents replay recursion.
- **Forward `push_file`/`pull_file`**: default destinations via
  `Filename.basename`; size caps (`TOPUP_XFER_MAX_BYTES`) enforced *before*
  reading/writing on both ends.
- **Subprocess spawns** (`local_session.ml`, `promote.ml`): all use argv-exec
  (`Unix.create_process`), never a shell string; session names sanitised.
- **Atomic writes**: `.tmp` + `Unix.rename` throughout.

## Residual / accepted

- **Cancel of a blocked `read_back`** is best-effort (pre-existing; tracked
  in the backlog), unaffected by these changes.
- **Forward push/pull and local `read_back`/`write_back` are unconfined** by
  design — the path is operator-chosen and local.
- **`next_id` wraparound** in `channel.ml` is unreachable in practice (63-bit
  counter) and left as-is.

## New environment variables

- `TOPUP_BACKCHANNEL_ROOT` — confinement root for back-channel blob ops
  (default `$HOME/.topup/back`; `off` disables).
- `TOPUP_MAX_MESSAGE_BYTES` — per-frame JSON-RPC byte cap (default 64 MiB).
