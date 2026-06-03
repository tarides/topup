# Backlog

Ordered list of pending work. The first item is the current task. New
ideas that arise mid-session get appended to the **end**, never inserted
ahead of the current task. See `.claude/skills/session-backlog/SKILL.md`
for the workflow.

## Unix-socket transport for `topup-mcp`

Add a `--socket <path>` mode that binds a Unix socket and dispatches
newline-delimited JSON-RPC against the same long-lived `Session.t`.
No HTTP, no protocol changes — just rebind stdio to a socket and
accept connections in a loop. Single-session semantics carry over
unchanged; the dispatcher serialises requests across connections.

Motivation is **debugging and reproducible test fixtures**, not
multi-client serving. With the socket in place, the client side is
generic Unix plumbing — no new topup binary needed:

```sh
  $ topup-mcp --socket "$TMPDIR/topup.sock" &
  $ echo 'let x = 1+2;;' \
  >   | jq -Rsc '{jsonrpc:"2.0",id:1,method:"tools/call",
  >               params:{name:"eval",arguments:{source:.}}}' \
  >   | ncat -U "$TMPDIR/topup.sock" \
  >   | jq -r '.result.value_repr'
  val x : int = 3
```

Each dune cram `$` stanza is a fresh process talking to the same
long-running daemon over the socket; state persists across stanzas
because the shell holding the daemon is one long-lived process (see
`cram_exec.ml:create_sh_script` — every stanza runs in a single
`main.sh`).

Knock-on uses:

- **Cram-based regression tests** for the eval pipeline driven from
  `.t` files (the `lattice.t` shape, but stateful across stanzas).
- **Transcript replay**: an agent's real MCP session, tee'd into a
  cram-shaped `.t` file, becomes a deterministic regression
  fixture. See the earlier discussion on `.t`-as-transcript.
- **Live introspection** while a session is running — attach a
  second client, run `env` / `lookup` without disrupting the agent.

Smallest form of [[HTTP / daemon transport]]: same shape, no HTTP,
no multi-client concurrency. Unblocks the [[Remote execution via
SSH port forwarding]] item too — SSH forwards Unix sockets
natively.

DESIGN.md, phase-1 implementation choice "MCP transport" (currently
"stdio only"); "Out of scope (initial)" — distributed sessions
become reachable once a socket exists.

## Idle-detection contract for background fibres

When does `eval` finish if the phrase spawns Lwt/Eio fibres? Default
contract should be: `eval` returns when the top-level expression
returns; background fibres are the user's problem and die at `reset`.
Decide, document loudly in `eval`'s tool description, and add a test
that confirms a phrase spawning an Lwt fibre does not extend `eval`.

DESIGN.md, "Must answer before phase-1 ships".

## LLM-in-the-loop smoke tests

Unit tests on `Session` and the in-process MCP integration exist.
Phase-1 still wants an end-to-end smoke test driven by a real model:
boot the server, drive a representative workflow (define values, use
them across turns, hit cancel, hit reset), assert the externalized-
memory thesis actually holds in practice. Scriptable from Claude Code
via the `/caml` skill or directly via MCP.

DESIGN.md, "Must answer before phase-1 ships".

## Assess first consumer's actual library needs

If the first real consumer needs a large library (mmapped dataset,
C-stub-heavy bindings) loaded from turn 1, then `load` and pre-warming
move out of phase-2-deferred and into phase-1-must-ship. Find out
before sinking more time into deferred work.

DESIGN.md, "Pragmatic / consumer-side".

## `load(path)` — Dynlink a .cmxs plugin

First phase-2 tool. Let the model bring a library into scope without
rebuilding the driver. Builds on the `ocaml_plugin` shape (driver
bytecode, plugins native `.cmxs`). Unblocks the larger native-JIT
story below.

DESIGN.md, phase-2 tool table; "Native-speed evaluation" section.

## Batched eval (`eval_batch`)

Per-phrase round-trip cost (~150 ms compile + protocol overhead)
dominates for tight inner loops. `eval_batch([source; …])` is probably
load-bearing at agent-loop rates. Decide shape: one error stops the
batch vs. continue-on-error with per-phrase results.

DESIGN.md, "Can defer (phase-2 or later)".

## Phrase-level JIT via `ocamlopt -shared` + Dynlink

Native-speed evaluation for the workloads the externalized-memory
thesis is actually designed for (search indices, parsed corpora,
log analysis). Compile each phrase to `.cmxs`, `Dynlink` it, keep the
driver bytecode. Lifts the current bytecode-only constraint for *user
phrases* without making the driver native.

DESIGN.md, "Native-speed evaluation"; phase-1 implementation choice
"Driver model".

## Checkpoint / restore via phrase replay

`checkpoint(label)` records the phrase log up to that point;
`restore(label)` spawns a fresh toplevel and replays. Composes with
the existing persistent phrase log. Slow but sound — Marshal of
Dynlinked closures is broken (ocaml/ocaml#5215), so replay is the
only honest option.

DESIGN.md, phase-2 tool table; "Snapshots" section.

## `compile_to_binary(entry, out)`

Promote a stable query out of the toplevel: serialize phrases
reachable from `entry`, freeze the binding environment, emit a
standalone `.ml`, build with dune, produce a native binary. The
exploration → production path that keeps `topup` honest. Selection
strategy (source-reachability vs. user-curation) is a real design
question, not an implementation detail.

DESIGN.md, phase-2 tool table; "What the LLM gets".

## Session pooling + pre-warming

Cold-loading large datasets is expensive. Pre-warm at server start;
keep a small pool of hot replicas for parallel exploration. Branch
cheaply via replay-based checkpoints. Decide naming (explicit session
parameter vs. implicit via client identity; design says both, named
takes precedence).

DESIGN.md, "Session pooling and routing".

## Jupyter kernel frontend

The toplevel core is already a library. A Jupyter frontend slots in
beside `topup-mcp`: streamed stdout, async display, interrupt — all
native to the protocol. Looks straightforward; worth doing once the
core stabilises.

DESIGN.md, "Protocol: MCP, Jupyter, or both"; phase-1 implementation
choice "Code structure".

## Direct CLI / pipe frontend

For testing and humans. Cheap once the core is library-shaped.

DESIGN.md, "Protocol: MCP, Jupyter, or both".

## Bubblewrap sandbox profile

LLM-generated OCaml has full process privileges by default. Ship a
sandbox profile: read-only bind mounts (OCaml install + session
data), writable tmpfs at `/tmp/topup-scratch`, network-namespace
isolation, CPU/wall-clock caps. In-process safety is nil — sandbox
catches syscall-level escape only; the design already assumes the
toplevel process can die or be corrupted.

DESIGN.md, "Sandboxing".

## Per-client sandbox policy

mcp-repl differentiates by client identity (Claude vs. Codex split).
Decide: a single configurable policy or a per-client lookup. Probably
defer until a second client materialises.

DESIGN.md, "Can defer (phase-2 or later)".

## Display-hook / standard-printer discovery

`#install_printer` already works through the eval pipeline (recorded
in commit `d5bf63d`). Open question is *how* a session declares its
standard printers without coupling `topup` to any particular library.
Options: a discovery mechanism, a per-package `topup_printers.ml`
convention.

DESIGN.md, "Can defer (phase-2 or later)".

## HTTP / daemon transport

Stdio is the v1 transport. HTTP / daemon mode unlocks longer-lived
servers, multi-client access, remote toplevels. Defer until a concrete
need lands.

DESIGN.md, phase-1 implementation choice "MCP transport".

## Versioning strategy for compiler-libs instability

`compiler-libs` has no backwards-compatibility guarantee — every
project that wraps it has taken a position. Four precedents:

- **Merlin** — per-OCaml-version branches and a version suffix
  `M.m[.p]-NNN` (`4.17.1-501` is Merlin 4.17.1 for OCaml 5.01,
  `5.7.1-504` is for OCaml 5.04). `main` tracks the latest. Closest
  analogue to topup: heavy compiler-libs consumer bound to the host
  typechecker.
- **ppxlib** — shadows compiler-libs behind a frozen AST with
  bidirectional migration; PPX authors only see ppxlib's parsetree.
  Heavy hub-and-spoke infrastructure that pays off across many
  downstream consumers. Overkill for a single-binary tool.
- **ocamlformat** — vendors *multiple* parsetree snapshots
  (`Ocaml_413_extended`, `Parser_extended`, …) and lets one binary
  format source for different OCaml language versions via the
  `ocaml-version` config. Broad opam floor, no tight upper bound
  (`ocamlformat-lib` 0.29.0 declares only `ocaml >= 4.14`). Works
  because it's a *static-text* tool: parse source, print source —
  no runtime coupling. Also split into binary + library
  (`ocamlformat` + `ocamlformat-lib`) so embedded users can consume
  the lib directly.
- **utop / ocaml-jupyter** — tight opam interval
  (`ocaml { >= "X" & < "Y" }`) per release, lean on `opam switch`
  to isolate. Small surface; one line per supported major.

ocamlformat's vendor-snapshots trick is **not directly applicable**
to topup. topup touches execution APIs (`Toploop.execute_phrase`,
`Outcometree`, dynamic environment, capture) that are bound to the
host runtime's compiler-libs — there is no "vendor an older
Toploop". That puts topup squarely in Merlin's neighbourhood. The
one ocamlformat lesson that does transfer is the binary/library
split, which topup already has via dune.

For topup at v0.1.0, do the utop/jupyter shape now: tighten the opam
upper bound to a closed interval against the current floor (today
that means `ocaml { >= "5.1" & < "5.4" }` or whichever upper bound
matches reality). Keep one version line. Defer Merlin's `M.m-NNN`
suffix scheme until OCaml N+1 actually breaks the build — adopting
it pre-emptively is overhead before there is evidence of breakage.
At that point, fork: maintain the old line for legacy switches,
start a new line for the new compiler, adopt the suffix to
disambiguate.

Worth doing immediately regardless: add a canary in the test suite
that exercises the compiler-libs surface topup actually depends on
(`Toploop.execute_phrase`, the `Outcometree.out_phrase` shape,
`Location.error_of_exn`) so the next compiler bump fails loud and
early rather than at user runtime.

Prior art: Merlin opam versions list; ppxlib compatibility docs;
ocamlformat-lib opam constraint; ocaml-jupyter's `jupyter.opam`.

## Remote execution via SSH port forwarding

For workloads where the data lives on a different machine than the
agent (large mmapped corpora on bulk-storage hosts, NVMe-bound runs
on a compute box), the toplevel should run on the remote and the
MCP server stays local. Pattern from `tarides/sudo-proxy`: ship a
static `topup` binary to the remote, then have the MCP server
spawn `ssh -t -L <local.sock>:<remote.sock> HOST topup-server` and
route subsequent `eval` / `env` / `lookup` / `reset` / `cancel`
calls through the forwarded Unix socket transparently. The
sudo-proxy `start_server({"host": …})` + per-request `host` field
is the worked example: tunnel setup amortised across many calls,
TUI/PTY allocated on the remote so stdout streams back unchanged.

Composes with the deferred HTTP / daemon transport: SSH forwards
Unix sockets natively, so any non-stdio shape unlocks remote mode
for free. Open questions: per-host session keying (one tunnel per
host vs. one per session), `forward_agent`-style opt-in for
fetching private deps on the remote, how `reset` and `cancel`
behave across a possibly-dead tunnel, where the persistent phrase
log lives (local mirror vs. remote-only).

DESIGN.md, "Out of scope (initial)" — "Distributed sessions
(toplevel on a remote host, MCP server local). Possible later;
first prove local value." Cross-references [[HTTP / daemon
transport]] above.

Prior art: `tarides/sudo-proxy` README, "Deploying to a remote
host" and "Usage" sections; in particular the
`ssh -t -L /tmp/sudo-proxy-HOST.sock:/run/user/$(ssh HOST id -u)/sudo-proxy.sock HOST sudo-proxy`
recipe and the MCP `start_server` / `execute(host=…)` shape.
