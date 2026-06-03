# Changelog

Completed work, most recent at top. See `backlog.md` for pending work
and `.claude/skills/session-backlog/SKILL.md` for the workflow.

## 2026-06-04 — Expand cram coverage for the socket transport

Follow-up to the socket-transport entry below. The original
`test/socket.t` was a single state-persistence smoke; this turns it
into a full surface walk and adds a second fixture for daemon /
socket-file lifecycle.

- `test/socket_client.ml` grew three subcommands: `env [filter]`
  (prints `name : type` sorted, `(empty)` when no bindings),
  `lookup <name>` (prints `name : type` or `(not found)`), and
  `reset` (prints the tool's text result, e.g. `ok`). The existing
  `request` and `eval` subcommands are unchanged; one new
  `do_call ~path ~name ~args ~handle` helper centralises the
  connect/send/recv/close dance.
- `test/socket.t` now exercises eval (success + type error), env
  (with two bindings, sorted), lookup (hit + miss), reset, and
  post-reset env / lookup — each as a separate connection, so the
  fixture doubles as an assertion that state survives between
  connections for every tool. Sandboxed via `TOPUP_LOG=off` and
  `TOPUP_SPILL_DIR="$PWD/spill"` so the daemon doesn't write into
  the developer's `~/.topup/`.
- `test/socket_lifecycle.t` (new) covers the daemon side: bad argv
  (`--bogus`, `--socket` with no path) → exit 2 + usage line;
  live-peer refusal — second daemon on the bound path exits 1 with
  the *socket in use* message; SIGTERM cleanup — socket file
  unlinked after the daemon dies; stale-file recovery — `touch` a
  plain file at the socket path, observe the next daemon unlinks
  it and binds a real socket in its place.

Both `.t` files passed locally; `dune runtest --force` is green
across `test_session`, `test_mcp`, `socket.t`, and
`socket_lifecycle.t`. The cram surface now substantially overlaps
with `test_mcp.ml` for the tool-call shape, but exercises it
through the real binary and a real Unix socket, so it catches
install / argv / signal-handler regressions that the in-process
pipe test cannot.

## 2026-06-03 — Unix-socket transport for `topup-mcp`

Closed the top backlog item. Added a `--socket <path>` mode that
binds a Unix domain socket and serves the same newline-delimited
JSON-RPC 2.0 protocol against the same long-lived `Topup.Session.t`.
Stdio mode is unchanged when no flag is given; `topup --socket
<path>` switches the binary into daemon mode.

Design decisions (locked with the user before implementation):

- **One connection at a time.** The accept loop services a single
  client until EOF, then accepts the next. No mutex in `lib/mcp`,
  no threads in production code — Toploop non-reentrance is
  preserved trivially. The deferred multi-connection-with-mutex
  variant (live introspection: attach a second client to run
  `env` / `lookup` without disrupting the primary) gets a new
  backlog item.
- **Probe-then-unlink stale paths.** If the socket file exists at
  startup, a probe `connect()` decides: success → refuse to start
  (live peer); `ECONNREFUSED` / `ENOENT` → unlink and bind. Stale
  files (e.g. after a `kill -9`) are recovered automatically; a
  running daemon is protected from accidental takeover.
- **Cleanup on exit.** `at_exit` unlinks the socket; a `SIGTERM`
  handler calls `exit 0` so the cleanup fires under normal shell
  termination. `SIGINT` is left to `Sys.catch_break` because the
  in-process cancel mechanism relies on it (`Session.cancel`
  delivers `SIGINT` to `main_pid`). `SIGPIPE` is ignored so a
  hung-up client raises `Sys_error` in the per-connection wrapper
  rather than killing the daemon.

Files:

- `lib/mcp/server.{ml,mli}` — new `serve_unix : path:string ->
  session:Topup.Session.t -> unit` plus a `prepare_socket_path`
  helper. `Server.run`'s transport-agnostic shape (`~ic ~oc
  ~session`) made the addition purely a wrapper; no refactor of
  dispatch was needed.
- `bin/main.ml` — hand-rolled argv match (no Cmdliner / Arg, since
  the binary still has only one flag). `Failure` from
  `serve_unix` (live-peer refusal, stat errors) is caught and
  printed as a single error line, exit 1.
- `dune-project` — `(cram enable)`.
- `test/dune` — new `socket_client.bc.exe` executable; `(cram
  (deps %{bin:topup} ./socket_client.bc.exe))` so cram tests get
  both binaries.
- `test/socket_client.ml` — small helper used by `.t` fixtures.
  Two subcommands: `request <json-line>` (raw round-trip) and
  `eval <source>` (builds the `tools/call eval` envelope, prints
  just `value_repr` or `ERROR: …`). Keeps cram expected-output
  blocks short and deterministic; avoids the `ncat` / `socat`
  dependency the backlog example used.
- `test/socket.t` — first cram fixture. Demonstrates the
  motivating scenario: state persists across separate client
  connections to the same daemon (`let x = 21 * 2;;` in one
  connection, `x;;` in the next, both print `42`). Also asserts
  the socket file is unlinked after SIGTERM.

Verified manually:

- Live-peer refusal — second `topup --socket <same path>` exits 1
  with `socket <path> is in use by another process`.
- Stale-file recovery — `touch <path>` to create a plain file,
  start the daemon, observe the file is unlinked and a real
  socket is bound in its place.
- Usage path — bad flag → `usage: topup-mcp [--socket <path>]`,
  exit 2.
- Stdio path is unaffected — `dune runtest` still drives the
  in-process pipe test the same way it did before.

## 2026-06-03 — Oversized-output policy: spill to files

Closed the first phase-1 backlog item. Picked the **files** half of
mcp-repl's `--oversized-output {pager,files}` split: when an eval's
`value_repr`, `stdout`, or `stderr` exceeds its inline cap, the field
is truncated with a `…[+N bytes; full at <path>]` marker and the full
content is written to a per-process spill directory. The eval result
gains three sibling fields — `value_repr_overflow`, `stdout_overflow`,
`stderr_overflow` — each `null` or `{ path; total_bytes }`.

Choice of *files* over *pager*: the agent's existing `Read` tool is the
client. No new MCP tool, no per-eval cursor state, no schema growth on
the request side. Matches topup's externalized-memory thesis — agent
holds the path, tool holds the content.

- New `lib/topup/spill.ml` + `.mli`: session-scoped overflow manager.
  Resolves the directory ($TOPUP_SPILL_DIR, else $HOME/.topup/spill;
  `off` disables), wipes it at `Session.create`, hands out sequence-
  numbered `NN-<field>.txt` files. Hard ceiling per file at
  `!Pretty.max_spill_bytes` (10 MiB default) with a tail elision marker
  so a runaway print loop cannot fill the disk.
- `Pretty` gains `max_stdout_bytes`, `max_stderr_bytes`, and
  `max_spill_bytes` refs alongside the existing `max_bytes`. All
  default to 8 KiB except `max_spill_bytes` (10 MiB).
- `Session.eval` now runs every large output field through
  `Spill.apply` after capture. `format_to_string` was refactored to
  return raw content; the cheap inline-elision path (used for type
  strings in `env` and `lookup`) goes through `Pretty.truncate_bytes`
  directly via a new `format_type_string` helper.
- `Tools.json_of_eval_result` exposes the three `*_overflow` fields
  with explicit nulls when absent. Eval tool description updated to
  tell the agent it should `Read` an advertised path if it needs full
  content.
- Tests: `test_session` exercises both stdout spill (>8 KB phrase)
  and value_repr spill (tight `max_bytes := 16`), asserts the inline
  marker mentions `full at`, asserts the file exists and has the
  expected prefix, asserts a small eval reports no overflow.
  `test_mcp` asserts the new fields are present in the JSON-RPC
  response, null for small evals, populated for a 20 KB
  `print_string` phrase.
- End-to-end smoke via raw JSON-RPC pipe confirmed: default mode
  spills to `$HOME/.topup/spill/`, `TOPUP_SPILL_DIR=off` keeps the
  inline marker but writes no file and reports `null` overflow.
- Cleanup discipline: spill dir is wiped on `Session.create` (one per
  process), not on `reset()`, so paths the agent saw earlier in the
  conversation stay readable.
- `CLAUDE.md` gained an "Oversized output" section documenting the
  cap, the env var, the disable sentinel, and the four tuning refs.

## 2026-06-03 — Backlog grooming: socket transport bumped to priority 2

Curatorial session, not work on the current task. Three changes to
the backlog, motivated by an exploration of how `lattice.t`-style
dune cram tests could be derived from `topup`:

- **Removed** "Consult Thibaut Mattio on ocaml-mcp interop" from
  `backlog.md` and the matching "Pragmatic / consumer-side" bullet
  from `DESIGN.md`. The `tmattio/ocaml-mcp` prior-art mentions in
  DESIGN.md's related-projects section stay — they describe the
  project, not an action item.
- **Added** "Remote execution via SSH port forwarding" at the
  bottom. Pattern from `tarides/sudo-proxy`: ship a static binary
  to the remote, tunnel a Unix socket over SSH, route subsequent
  MCP calls through it transparently. Cross-references the
  existing "HTTP / daemon transport" item.
- **Added** "Unix-socket transport for `topup-mcp`" as priority 2,
  immediately after the current task. Minimum-viable form of the
  deferred daemon transport: `--socket <path>` mode, same JSON-RPC,
  no HTTP. Once the server binds a socket, the client side is
  `ncat -U` + `jq` — no new `topup` binary needed. Dune cram is
  the motivating use case: a `main.sh` runs all stanzas in one
  shell, so a daemon started in stanza 1 is reachable from
  stanzas 2..N (verified by reading `cram_exec.ml:create_sh_script`).

Build and tests green; no source changes.

## 2026-06-03 — Bootstrap of the bootstrap

Adopted the session-backlog discipline: a `backlog.md` of ordered
pending work (current task first, new ideas appended to the end) and
this `changelog.md` of completed work (most recent at top). One
backlog item per session; the wrap-up step moves the finished item
from one file to the other. The skill at
`.claude/skills/session-backlog/SKILL.md` codifies the rules.

Seeded the backlog from DESIGN.md's "Phase-1 planning" tiers and the
Phase-2 tool table, with the "Must answer before phase-1 ships" items
at the top. Seeded the changelog with this entry plus the rollup of
work-to-date below.

## 2026-06-03 — Initial project setup

Brought `topup` from design sketch to a shipped Phase-1 MVP: a
single-session OCaml toplevel exposed as an MCP server over stdio,
with `eval`, `env`, `lookup`, `reset`, `cancel` tools.

Highlights from the road to here, in rough order:

- Design sketch (`DESIGN.md`) — externalized-memory thesis, phase-2
  roadmap, situated against `tmattio/ocaml-mcp`, `posit-dev/mcp-repl`,
  `ocaml-jupyter`, `utop`, `Down`.
- Phase-1 MVP implemented: `Session` (Toploop wrapper) + `Capture` (fd
  dup2 + drain threads) + `Pretty` (depth/byte caps) + `Error`
  (`Location.error_of_exn` → structured JSON), MCP `Rpc`/`Server`/
  `Tools` over newline-delimited JSON-RPC 2.0.
- Operational hardening: `Sys.Break` mapped to a cancellation error;
  stdlib hidden from `env` by default (`is_user_origin` filter);
  `value_repr` capped at the printer *and* at the byte level;
  findlib/topfind initialised so `#require` works;
  `#install_printer` confirmed working through the eval pipeline.
- Persistent phrase log: each error-free phrase is appended to
  `$HOME/.topup/history.ml` (`TOPUP_LOG` override, `off` to disable).
  Directives skipped to prevent replay recursion. Log path treated as
  a user-origin location for `env`.
- Packaging: bytecode-only throughout (`compiler-libs.toplevel` ships
  no native impl); `topup` made opam-installable; project-scope
  `.mcp.json` plus user-scope `claude mcp add` flow documented.
- `/caml` slash-command skill wrapping the MCP tools, with utop-style
  `#env` / `#lookup` / `#reset` / `#cancel` directives.
- Docs split: `README.md` for the pitch and install, `DESIGN.md` for
  the rationale and phase-2 roadmap, `CLAUDE.md` for operational notes
  and house rules.
