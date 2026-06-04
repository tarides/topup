# CLAUDE.md

Operational notes for working in this codebase. See `README.md` for the
pitch and `DESIGN.md` for the rationale and phase-2 roadmap.

## Build and test

Always go through `opam exec --` (per the user's global preference; do
not use `eval $(opam env)`):

- `opam exec -- dune build @all` — full build
- `opam exec -- dune runtest --force` — unit + in-process MCP integration
- `opam reinstall topup --working-dir --yes` — reinstall in current switch

Everything is **bytecode-only** because `compiler-libs.toplevel` ships no
native implementation. The libraries set `(modes byte)`, the binary uses
`(modes byte_complete)`. Don't add native modes.

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
bin/main.ml   wires Session + Server to stdin/stdout (default) or
              to a Unix socket via `--socket <path>`; or runs as a
              bridge via `--proxy <path>` / `--remote <host>`;
              reads TOPUP_LOG
test/         test_session.ml (unit) + test_mcp.ml (in-process MCP)
              + socket.t, socket_lifecycle.t, proxy.t, checkpoint.t
              (cram against the binary)
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
  `cancel`, `load`, `checkpoint`, `restore`, `start_session`,
  `restart_session`, `update_host`.

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

Test hook for cram fixtures: setting
`TOPUP_HOST_SOCKET_<HOST>=/path/to/sock` (with `<HOST>`
uppercased) makes `start_session { host: "<host>" }` skip the SSH
spawn and connect to the named local socket directly. Test-only.

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
- Don't add native build modes anywhere.
- Don't put host-identifying paths (usernames, hostnames) in committed
  files. The CLAUDE.md global rule applies here too.
- Keep `(modes byte)` / `(modes byte_complete)` on all stanzas that
  transitively depend on `topup`.

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

## LLM-in-the-loop smoke test

`test/smoke/llm_playbook.md` is the operational end-to-end exercise: a
human (or Claude in a fresh session) walks four beats — define, use
across a turn, cancel, reset — and captures the transcript as
`test/smoke/replay_<YYYY-MM-DD>.md`. The Beat-2 step is the
externalized-memory thesis check (DESIGN.md §"The externalized-memory
thesis"). Not wired into `dune runtest`; not CI-gated.
