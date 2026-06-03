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
bin/main.ml   wires Session + Server to stdin/stdout (default) or to
              a Unix socket via `--socket <path>`; reads TOPUP_LOG
test/         test_session.ml (unit) + test_mcp.ml (in-process MCP)
              + socket.t, socket_lifecycle.t (cram against the binary)
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
- The five MCP tools are deferred — load schemas via
  `ToolSearch select:mcp__topup__eval,mcp__topup__env,…` before calling.

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
