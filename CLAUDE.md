# CLAUDE.md

Operational notes for working in this codebase. See `README.md` for the
pitch and `DESIGN.md` for the rationale and phase-2 roadmap.

## Build and test

Always go through `opam exec --` (per the user's global preference; do
not use `eval $(opam env)`):

- `opam exec -- dune build @all` — full build
- `opam exec -- dune runtest --force` — unit + in-process MCP integration
- `opam reinstall topup --working-dir --yes` — reinstall in current switch

Two binaries ship from the same source tree:

- **`topup`** — bytecode driver (`byte_complete`). Links
  `compiler-libs.toplevel`. Default; `Toploop.execute_phrase`
  evaluates each phrase in bytecode against the persistent typed
  environment.
- **`topup-opt`** — native driver (`exe`). Links
  `compiler-libs.native-toplevel`. Each user phrase is compiled with
  `ocamlopt -shared` and `Dynlink`-loaded; native-speed evaluation
  with ~150 ms compile latency per phrase. Opt in by pointing
  `.mcp.json`'s `command` at `topup-opt`. Name echoes the
  `ocamlc`/`ocamlopt` split — bytecode vs native backend, no JIT
  semantics implied.

`lib/topup`, `lib/mcp`, `lib/topup_entry` all build in both modes
(`(modes byte native)`). The mode-specific toplevel dependency is
supplied by two virtual-library implementations:

- `lib/topup_eval_byte/` — `(implements topup)` + `compiler-libs.toplevel`.
- `lib/topup_eval_native/` — `(implements topup)` +
  `compiler-libs.native-toplevel`. Also flips `Clflags.native_code`
  and `Clflags.dlcode` before `Toploop.initialize_toplevel_env` so the
  in-process compiler emits PIC suitable for `Dynlink`.

`lib/topup/eval_backend.mli` is the abstraction Session talks to;
both implementations expose `let X = Toploop.X` plus a backend-
specific `init_findlib`. **Do not** call `Toploop.*` directly from
`lib/topup`; route through `Eval_backend.*` so the same `Session`
code links into either binary.

## Layout

```
lib/topup/    Session API around Toploop (eval, env, lookup, reset, cancel)
              + Capture (fd dup2 + drain threads) + Pretty (depth/byte caps)
              + Spill (oversized-output overflow files)
              + Error (Location.error_of_exn → structured JSON)
lib/mcp/      newline-delimited JSON-RPC 2.0 over stdio or Unix
              socket: Rpc, Server (run + serve_unix), Tools
              + Proxy (stdio↔socket bridge, SSH wrapper for remote
              execution)
              + Host_registry / Remote_host (per-host SSH tunnels
              and JSON-RPC fan-out for `host:`-routed tool calls)
lib/topup_eval_byte/    virtual-lib impl: Toploop = compiler-libs.toplevel
lib/topup_eval_native/  virtual-lib impl: Toploop = compiler-libs.native-toplevel
lib/topup_entry/        Entry.run — shared MCP wiring used by both binaries
bin/main.ml             one-liner: `let () = Topup_entry.Entry.run ()`
                        (linked against topup_eval_byte → topup binary)
bin/main_opt.ml         same one-liner, linked against topup_eval_native
                        → topup-opt binary
test/         test_session.ml (unit) + test_mcp.ml (in-process MCP)
              + socket.t, socket_lifecycle.t, proxy.t, checkpoint.t,
              opt.t (cram against the binary; opt.t spawns topup-opt)
```

## Things you need to know to change `Session`

- `Toploop.print_out_phrase` is hooked per-eval to capture the
  `Outcometree.out_phrase`. The hook is restored after each eval; don't
  leave it dangling across calls.
- Toploop is **not reentrant** — one eval at a time, enforced implicitly
  by single-threaded MCP dispatch.
- Custom printers via `#install_printer` work transparently because Toploop
  embeds them in the Outcometree as `Oval_printer` nodes; `!Oprint.out_value`
  honours them.
- Sys.Break: `Toploop.execute_phrase` catches it and surfaces it as
  `Ophr_exception (Sys.Break, _)`. Match that constructor *before* the
  generic `Ophr_exception (exn, _)`, otherwise the user sees
  `"Stdlib.Sys.Break"` instead of `"evaluation timed out"`.
- The watchdog thread fires `SIGINT` to the main process pid. `Sys.catch_break true`
  must be set once at session create.
- `Capture.with_capture` does `Unix.dup2` over fd 1/2 to a pipe, drains in
  two threads, and restores. Pre-flushing `Format.std_formatter` /
  `Format.err_formatter` before and after the dup is essential — skipping
  the post-flush loses any user output that the channel was still buffering.
- `is_user_origin t file`: a binding is "user code" iff its `val_loc.file`
  is `"<eval>"` or matches `t.log_path`. The env filter defaults to user
  origin; `~all:true` brings stdlib + libraries back.

## Oversized output

`eval` returns three potentially-large fields: `value_repr`, `stdout`,
`stderr`. Each is capped inline (`Pretty.max_bytes`,
`Pretty.max_stdout_bytes`, `Pretty.max_stderr_bytes`; all default 8 KiB).
When the cap is exceeded, `Spill.apply` truncates the inline string with
a marker `…[+N bytes; full at <path>]` and writes the full content to a
spill file. The eval result gains a sibling `*_overflow` field
(`{ path; total_bytes }`) the consumer can use directly.

- Spill directory: `$TOPUP_SPILL_DIR` if set, else `$HOME/.topup/spill`.
- `TOPUP_SPILL_DIR=off` disables spilling entirely — the inline marker
  is still added (`…[+N bytes]`) but no file is written and
  `*_overflow` stays `null`.
- The directory is wiped at `Session.create` so spill files do not
  accumulate across restarts. Files survive `reset()` within a session
  so paths in earlier responses stay readable.
- Each spill file is hard-capped at `!Pretty.max_spill_bytes` (10 MiB
  default); content beyond gets a tail `…[+N bytes dropped]` marker.
- Long type strings (in `eval`'s `type` field and `env`/`lookup`
  bindings) still use the cheap `Pretty.truncate_bytes` path — they
  are not spilled.

## Persistent phrase log

`Session.create ?log_path` appends each error-free phrase to the given
file as raw OCaml. `bin/main.ml` defaults the path to
`$HOME/.topup/history.ml`, overridable via `TOPUP_LOG=<path>`, disabled
via `TOPUP_LOG=off`.

`log_phrase` **skips directives** (any phrase whose first non-whitespace
char is `#`). This prevents replay recursion: `#use "<log>"` evaluated
once would otherwise log itself, and the next replay would re-`#use` and
recurse until stack overflow. Don't remove this guard.

## Checkpoint / restore

`checkpoint(label)` copies the phrase log to
`$TOPUP_CHECKPOINT_DIR/<label>.ml` (default `$HOME/.topup/checkpoints/`);
`restore(label)` truncates the current log, copies the snapshot into
its place, calls `Session.reset`, and `#use`s the restored log. The
returned eval result reflects the replay — a non-null `error` means a
phrase failed mid-replay and the session is in an intermediate state.

- Override the directory via `TOPUP_CHECKPOINT_DIR=<path>`; `=off`
  disables `checkpoint` / `restore` (each returns a clear error).
- Labels must match `[A-Za-z0-9._-]+`, may not start with `.`, and may
  not contain `..`. Validated in `Session`, not just at the MCP edge.
- Writes are atomic (`<label>.ml.tmp` + `Unix.rename`); a crash mid-
  checkpoint cannot leave a partial file that `restore` would read.
- The directory is **not** wiped on `Session.create` — checkpoints
  must survive server restarts, that is the entire point.
- `#load`ed libraries are not in the phrase log. Restoring a
  checkpoint that depended on a loaded library will fail at
  typecheck; re-issue `load` first.
- `restore` replaces the live log so subsequent `eval` calls extend a
  log consistent with the current session.

## MCP / Claude Code integration gotchas

- `.mcp.json` at the repo root (gitignored) names the binary that Claude
  Code spawns. Project scope.
- A user-scope `claude mcp add` registration **shadows** the project scope.
  If reconnect is loading the wrong binary, check `claude mcp get topup`
  and remove the local-scope entry with `claude mcp remove topup -s local`.
- **`/mcp` Reconnect does not refresh the spawn path.** Editing
  `.mcp.json` mid-session does nothing until Claude Code itself is fully
  restarted (`/quit` then re-launch). This caught us repeatedly — every
  reinstall during a session was being tested against the previous
  spawn.
- The MCP tools are deferred — load schemas via
  `ToolSearch select:mcp__topup__eval,mcp__topup__env,…` before calling.
  The full set is `eval`, `eval_batch`, `env`, `lookup`, `reset`,
  `cancel`, `load`, `checkpoint`, `restore`, `compile_to_binary`,
  `push_file`, `pull_file`, `start_session`, `restart_session`,
  `update_host`, `start_local_session`, `restart_local_session`,
  `update_local_session`.

## Multi-host routing (per-call `host:`)

Every tool that takes session state (`eval`, `env`, `lookup`, `load`,
`reset`, `cancel`, `checkpoint`, `restore`) accepts an optional
`host: string`. Omit (or pass `"local"`/`""`) to hit the in-process
Toploop; pass any other name to route the call to a remote
`topup --socket` daemon over an SSH-forwarded Unix socket.

Lifecycle is explicit:

- `start_session { host }` — opens the SSH tunnel
  (`ssh -L <local>:<remote> <host> topup --socket <remote>`),
  performs the MCP `initialize` handshake, and registers the host.
  Idempotent on a live tunnel. Remote socket defaults to
  `~/.topup/sockets/topup.sock` on the remote side; pin it with
  `remote_socket: "<path>"`.
- `restart_session { host }` — kills the tunnel and re-spawns. Use
  when wedged; for a fresh OCaml environment use `reset` instead.
- `update_host { host, description?, os? }` — set/replace metadata
  surfaced in the `initialize` response's `instructions` block.

The `instructions` block, rebuilt on every `initialize`, enumerates
known hosts so a freshly-connected client sees what is registered
without re-querying.

The registry persists to `~/.topup/hosts.json` (override with
`TOPUP_HOSTS_FILE=<path>`; `=off` disables persistence). Live SSH
state is never written to disk — restarted servers come up with no
tunnels and require fresh `start_session` calls.

Concurrency is deliberately tight: the MCP server processes one
`tools/call` at a time; per-host serialisation is implicit. Parallel
fan-out to distinct hosts is a separate backlog item ("Multi-connection
socket transport with serialized dispatch").

## File transfer across the boundary (`push_file` / `pull_file`)

`push_file { host, local_path, remote_path? }` and
`pull_file { host, remote_path, local_path? }` carry bytes between
the MCP-server-local filesystem and a registered remote, in-band
over the existing forward JSON-RPC channel. `host:` is required —
purely-local copies are rejected. `session:` is rejected (mutually
exclusive with `host:`).

Implementation shape:

- Two public tools (`Tools.descriptors` entries) handle the
  composition. They don't go through the standard `host:`-routing
  dispatch — they extract `host:` themselves and originate two
  separate operations: local disk I/O + a routed `tools/call` to
  the internal `_recv_blob` / `_send_blob` primitive on the remote
  daemon side.
- `_recv_blob` and `_send_blob` are dispatchable by name in
  `dispatch_local` but are **not** in `Tools.descriptors`, so they
  do not appear in `tools/list`. The LLM-facing surface stays two
  tools wide; the bytes-transport tools are internal helpers.
- Payload is base64-encoded inside one JSON-RPC frame. Hard-capped
  at `TOPUP_XFER_MAX_BYTES` bytes (default 16 MiB). The cap is
  enforced before bytes are read on both sides.
- Default destination directory: `$HOME/.topup/xfer/`, overridable
  via `TOPUP_XFER_DIR=<path>`; `=off` requires explicit
  `remote_path`/`local_path`. Created lazily (not wiped on session
  create — these are explicit artefacts).
- Writes are atomic (`<path>.tmp` + `Unix.rename`) on both sides.

For chunked / streaming transfer (>16 MiB), see backlog
"Streaming / paged eval results".

Test hook for cram fixtures: setting
`TOPUP_HOST_SOCKET_<HOST>=/path/to/sock` (with `<HOST>`
uppercased) makes `start_session { host: "<host>" }` skip the SSH
spawn and connect to the named local socket directly. Test-only.

## In-phrase boundary crossing (`Topup.read_back` / `Topup.write_back`)

Two OCaml functions usable from inside an `eval`'d phrase that
reach back to the MCP-server-local filesystem (where the chatbot
lives). Counterpart to `push_file`/`pull_file` at the OCaml layer
rather than the MCP-tool layer.

```ocaml
val Topup.read_back  : string -> bytes
val Topup.write_back : string -> bytes -> unit
```

Routing follows the eval's destination, not the function's:

- **In-process eval (`host:` omitted/`"local"`):** direct file I/O
  on the daemon's own filesystem via `Topup_runtime.direct_hook`.
- **Named local session (`session:`):** same — the subprocess
  shares the chatbot's filesystem, so no muxer needed.
- **Remote eval (`host:` set):** the remote daemon's `Server.run`
  installed a muxed hook on connection accept. Each
  `Topup.read_back` originates a JSON-RPC `_send_blob` request
  back over the same SSH-forwarded socket; the local daemon's
  `Remote_host`-side `Channel` reader dispatches it via
  `Blob.dispatch` and writes the response. Bytes never touch
  disk on the remote side.

Implementation shape:

- `lib/topup_runtime/` is a small leaf library (`topup.runtime` in
  findlib). It holds `current_hook : io_hook ref`, defaulted to
  `direct_hook`. `Session.create` evaluates the prelude
  `module Topup = Topup_runtime;;` so the user-visible name is
  `Topup` (the `.cmi` search path is added by
  `Eval_backend.prepare_topup_runtime`; the bytecode is statically
  linked, so the prelude does not `#require` — `Topfind.don't_load`
  marks the package preloaded).
- `lib/mcp/channel.ml` is the bidirectional muxer over a
  newline-delimited JSON-RPC socket: writer mutex, reader thread
  that demuxes responses (slot lookup) vs inbound requests (queued
  to a single dispatcher thread that serialises in arrival order)
  vs notifications (own thread, so cancel can interrupt an
  in-flight eval rather than queueing behind it).
- `lib/mcp/blob.ml` is a stateless helper with `_send_blob` /
  `_recv_blob` semantics (mirror of the same names in
  `Tools.dispatch_local`); the Remote_host channel's `on_request`
  delegates to it.
- `lib/mcp/server.ml`'s `run` installs the muxed hook on accept,
  restores `direct_hook` on close. Session-touching tools serialise
  on a per-connection `eval_mu`; blob tools intentionally bypass it
  so a back-channel call can interleave while an eval is in flight.

Cap and atomicity: same `TOPUP_XFER_MAX_BYTES` (16 MiB default) as
push/pull; writes are atomic (`<path>.tmp` + `Unix.rename`).

Cancel semantics (v1): best-effort. If `Topup.read_back` is blocked
on `Condition.wait` for a back-channel response, `SIGINT` does not
unblock it. The peer's reply (or its EOF) will eventually wake the
slot. Tracked in the backlog as a follow-up.

Deployment note: `topup.runtime` ships in the same opam package as
`topup`; no extra installs. Remotes running `topup --socket` must
be the same version as the local — older daemons will fail their
session prelude when they don't find `topup.runtime` on the
typechecker's load path.

## Named local sessions (per-call `session:`)

Same surface as `host:` but for local subprocesses. Every state-bearing
tool also accepts an optional `session: string`; omit or pass
`"local"`/`""` for the in-process Toploop, pass any other name to
route the call to a `topup --socket` subprocess managed by the same
server. `session:` and `host:` are **mutually exclusive** — passing
both yields a routing error.

Lifecycle is explicit and parallel to the host lifecycle:

- `start_local_session { session, prewarm?, pool? }` — forks
  `topup --socket <path>`, runs the MCP `initialize` handshake, and
  (when `prewarm` is given) evaluates `#use <prewarm>;;` before
  returning. A failing prewarm kills the subprocess and surfaces the
  error. When `pool > 1`, also spawns siblings named
  `<session>.1` … `<session>.(pool-1)` sharing the same prewarm.
  Idempotent on a live session.
- `restart_local_session { session }` — kills and re-spawns. Use
  when wedged; for a fresh OCaml environment within the same
  subprocess use `reset { session }` instead.
- `update_local_session { session, prewarm?, pool? }` — updates the
  persisted metadata (not the live subprocess; restart to apply).

Subprocesses inherit the parent server's environment, so
`TOPUP_CHECKPOINT_DIR` and `TOPUP_SPILL_DIR` are shared by default —
which is why `checkpoint { session: "a", label: "L" }` followed by
`restore { session: "b", label: "L" }` branches off "a" without any
extra plumbing.

Persistence: registry metadata (name, prewarm, pool size, last_seen)
goes to `~/.topup/sessions.json`. Override via
`TOPUP_SESSIONS_FILE=<path>`; `=off` disables. Live subprocess state
is never persisted — restarted servers come up with no live sessions
and require fresh `start_local_session` calls.

Test hook: `TOPUP_SESSION_SOCKET_<NAME>=/path/to/sock` (with
`<NAME>` uppercased) makes `start_local_session { session: "<name>" }`
skip the subprocess spawn and connect to the named socket directly.
Test-only; mirrors the `TOPUP_HOST_SOCKET_*` hook for cram fixtures.

## Remote execution (single-host shortcut)

Two flags layer to put the toplevel on another host:

- `topup --proxy <socket-path>` — stdio↔Unix-socket bridge.
  Bidirectional byte pump from stdin/stdout to the named socket. The
  socket is connected with a retry loop (default 10 s) so the bridge
  rides out the case where the peer hasn't bound the path yet. No
  JSON parsing: framing is the wire's responsibility.

- `topup --remote <host> [--remote-socket <path>]` — pre-registers
  `<host>` and sets it as the `default_host` of an in-process MCP
  server on stdio. A client sending `eval` with no `host:` gets
  evaluation on `<host>`; an explicit `host: "local"` still escapes
  to the in-process Toploop. Under the hood this calls
  `Host_registry.start_session`, which uses the same SSH-spawn helper
  (`Proxy.spawn_ssh`) as `start_session` from a live server.
  `<remote.sock>` defaults to `~/.topup/sockets/topup.sock` on the
  remote host; pin a different path with `--remote-socket`. `at_exit`
  closes all live tunnels; SIGTERM/SIGINT handlers fire under shell
  termination.

The remote side is the same `topup --socket` binary — no special
build. Install topup on the remote host in advance (`opam install
topup`); the local proxy does the rest.

Manual smoke (not CI-gated; same tier as the LLM-in-the-loop smoke):

```
ssh-copy-id <host>              # one-time
opam reinstall topup --working-dir --yes

printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
  | _build/default/bin/main.bc.exe --remote <host>
```

Expect: an `initialize` response with `serverInfo.name = "topup"`,
and a `topup --socket /tmp/topup-*.sock` process visible on the
remote. Killing the local proxy unlinks the local socket and
disconnects SSH, which terminates the remote process.

Known limitations:

- **Phrase log, spill files, and checkpoints are remote-only.** The
  remote `topup` writes its log, spill files, and checkpoints under
  the remote user's `$HOME`. The local agent's `Read` tool cannot
  reach them.
- **Dead tunnel = local proxy exits.** No auto-reconnect. Restart
  the MCP client to reconnect; with `--remote-socket` pinned, the
  surviving remote daemon keeps the session.
- **One tunnel per `--remote` invocation.** Multiple sessions on
  the same host need multiple `.mcp.json` entries with distinct
  `--remote-socket` paths.
- **Cancel works through the tunnel.** `notifications/cancelled`
  flows as any other message; `Session.cancel` delivers SIGINT to
  the remote `main_pid`.

## `/caml` skill

`.claude/skills/caml/SKILL.md` is the slash-command convenience layer
around the MCP tools. Bare `/caml <source>` → `mcp__topup__eval`;
`/caml #env|#lookup|#reset|#cancel` → the corresponding tool; `/caml
#env --all` passes `all: true`. The `#` prefix matches OCaml's
toplevel-directive convention; only the directives in that table are
reserved — every other input is OCaml source.

## House rules

- **Don't use the `Str` module.** Not yet deprecated but on track. Inline
  helpers for substring search; `re` opam package for richer regex.
- Don't put host-identifying paths (usernames, hostnames) in committed
  files. The CLAUDE.md global rule applies here too.
- Keep `(modes byte native)` (or the appropriate single mode) on
  stanzas under `lib/`; only the binaries are mode-specific
  (`byte_complete` for `topup`, `exe` for `topup-opt`). When adding a
  new library that needs the toplevel, route Toploop calls through
  `Eval_backend` and supply both byte/native implementations — never
  hard-depend on `compiler-libs.toplevel` or
  `compiler-libs.native-toplevel` from a generic library.

## Dogfooding

The fastest way to test a change end-to-end:

1. `opam exec -- dune build @all` and `opam exec -- dune runtest --force`
2. `opam reinstall topup --working-dir --yes`
3. Fully restart Claude Code (not Reconnect) to swap binaries
4. Exercise via `/caml` or direct `mcp__topup__*` calls

For pure stdio smoke tests without a Claude Code restart, pipe JSON-RPC
through the binary directly:

```
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"eval","arguments":{"source":"1+2;;"}}}' \
| _build/default/bin/main.bc.exe
```

For the native (`topup-opt`) path, swap the binary:

```
... | _build/default/bin/main_opt.exe
```

Same JSON-RPC; the difference is per-phrase `ocamlopt -shared` +
`Dynlink` underneath `Toploop.execute_phrase`.

## LLM-in-the-loop smoke test

`test/smoke/llm_playbook.md` is the operational end-to-end exercise: a
human (or Claude in a fresh session) walks four beats — define, use
across a turn, cancel, reset — and captures the transcript as
`test/smoke/replay_<YYYY-MM-DD>.md`. The Beat-2 step is the
externalized-memory thesis check (DESIGN.md §"The externalized-memory
thesis"). Not wired into `dune runtest`; not CI-gated.
