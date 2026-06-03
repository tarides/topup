# topup

> An OCaml toplevel exposed as an MCP server, designed for LLM-driven interactive workflows.

**Status:** design sketch. No code yet.

## Name

Three readings, all intentional:

- **top** — from "toplevel", OCaml's REPL.
- **up** — pairs with Daniel Bünzli's [`Down`](https://erratique.ch/software/down). `Down` enhances the toplevel *for humans at a keyboard*. `topup` exposes the toplevel *upward*, to a higher-level consumer — an LLM, an agent, a notebook kernel.
- **top up** — what you do to a phone, a fuel tank, or a stash of working memory. `topup` is durable typed scratch space for an LLM whose context window is bounded.

## Motivation

LLM-driven coding assistants run into two connected problems whenever they work in a typed compiled language:

1. **Iteration latency.** Each idea costs a build cycle: edit, dune build, run, read output. The model burns wall-clock time and tokens on rebuilds that the toplevel would skip.
2. **Working-memory pressure.** Intermediate values — a parsed dataset, an expensive index, a partially-explored data structure — either get re-derived every turn (wasting tokens and time) or get serialized into the context window (wasting tokens). Neither is right.

Type-feedback latency is sometimes cited as a third problem, but Merlin/`ocamllsp` already give sub-100 ms type errors incrementally. The toplevel isn't faster than Merlin at typechecking; it's faster than `dune build` at *running*. The wins are about **evaluation**: skipping the build for execution, and keeping intermediate values live across turns.

OCaml already has the runtime that solves both. Stock `ocaml`, `utop`, and the `Toploop` library evaluate phrases incrementally against a persistent typed environment, with durable bindings across turns. `topup` wraps that runtime so an LLM can use it directly.

## What the LLM gets

A small set of tools, sufficient to use a long-lived toplevel as the model's working environment. The **Phase** column marks the v1 cut:

| Tool | Phase | Effect |
|------|-------|--------|
| `eval(source)` | 1 | Evaluate one or more OCaml phrases. Returns `{value_repr, type, stdout, warnings, error}`. Errors are structured: `{phase: typecheck \| runtime, location, message, related}`. |
| `env(filter?)` | 1 | List current bindings as `[(name, type)]`. Filters by recency, type prefix, or namespace — unfiltered output doesn't scale past a few dozen bindings. The model's RAG-over-self primitive. |
| `lookup(name)` | 1 | Inspect one binding: type, brief value preview, source location if available. |
| `cancel()` | 1 | Interrupt the currently-running phrase. Also exposed as an input-prefix byte (cf. mcp-repl's ``), so the model can interrupt without a separate tool round-trip. Wall-clock caps catch the model that forgets; this catches the one that doesn't. |
| `reset()` | 1 | Discard the current session and start fresh. Escalates graceful → forceful → descendant-process scan (mcp-repl's approach; necessary when a Dynlinked C stub leaves zombie threads). |
| `load(path)` | 2 | `Dynlink` a `.cmxs` plugin (libraries the model wants in scope). |
| `checkpoint(label)` / `restore(label)` | 2 | Save and restore a named session state via **phrase replay**, not value Marshal. See "Snapshots" below for why. |
| `compile_to_binary(entry, out)` | 2 | Promote a validated query: serialize phrases reachable from `entry` + freeze the binding environment into a standalone `.ml` file, build with `dune`, emit a native ELF for production runs. |

The Phase-2 promotion via `compile_to_binary` is what keeps `topup` honest. The toplevel is for *exploration and refinement*; once a query is stable, it leaves the toplevel and runs as a normal native binary — same source, no toplevel dependency at runtime.

Selecting which phrases enter `compile_to_binary` is a real design choice, not an implementation detail: source-level reachability from `entry` is the default; user-curation is the escape hatch. Naive "serialize all phrases the session ever evaluated" produces broken builds.

## The externalized-memory thesis

This is the part of the design that justifies `topup` versus just-use-utop.

A typical LLM coding loop:

```
turn N:   model evaluates `let parsed_corpus = ... (* expensive *)`
turn N+1: model wants to refer to `parsed_corpus`
          → must either re-derive it (slow, wasteful) or
            paste its serialized form into context (token-expensive)
```

With `topup`, turn N+1 just references `parsed_corpus` by name. The toplevel holds the value; the model holds the *name and type*. Cost: one symbol in the context, instead of N kilobytes of data. The OCaml type system makes this recall *sound* — the model can't accidentally use `parsed_corpus` somewhere a `document list` is expected; the compiler will catch it before evaluation.

This inverts the usual pattern (model carries state in context, tool is stateless). Here the tool carries state, the model carries only names + types + intent. Analogous to Claude Code's memory files but typed, programmatic, and live.

**The general pattern isn't novel.** Posit's [`mcp-repl`](https://github.com/posit-dev/mcp-repl) (R + Python) ships a stateful REPL-as-MCP with explicitly the same pitch — "a shell tool keeps forcing the agent to rebuild context; mcp-repl keeps the session open instead." The persistence-beats-stateless argument is in the air. What's specific to `topup` is the combination that the dynamic-language variants can't offer: typed recall (the type system makes name reuse *sound*), native-speed evaluation, and a promotion path to a standalone binary. See "Relation to existing tools" below.

**Honest caveat.** A type signature for a record with 47 fields tells the model the *type*, not what's *in* `parsed_corpus`. In practice the model will call `lookup` often, partially refilling context with previews. The thesis trades "values inlined in context" for "many cheap typed lookups," not for free recall. That's still a big win — `lookup` returns *exactly* what the model asks for, on demand — but it's not magic.

## Native-speed evaluation

Stock `ocaml` is bytecode. For most interactive work that's fine, but for LLM-driven workloads that walk large datasets — search indices, parsed corpora, structured-log analysis — bytecode evaluation is too slow.

Two viable strategies:

1. **`ocamlnat` (native toplevel).** Real, recently improving, historically rough. Worth a fresh evaluation.
2. **Phrase-level JIT via `ocamlopt -shared` + `Dynlink`.** Keep the driver in bytecode/native; compile each user phrase to a `.cmxs` and `Dynlink` it. ~150 ms compile latency per phrase, native-speed evaluation afterward. Used by Jane Street's [`ocaml_plugin`](https://github.com/janestreet/ocaml_plugin); proven approach.

Default to (2); revisit (1) once `ocamlnat` quality is verified on current OCaml.

## Sandboxing

LLM-generated OCaml has full process privileges by default — `Sys.remove`, `Unix.fork`, network, arbitrary file I/O. OCaml's effect system (5.x) is not capability-typed, so a pure-language sandbox is not on offer.

Pragmatic approach: run the toplevel under `bubblewrap` with

- read-only bind mounts of the OCaml installation + any data the session needs,
- a writable scratch tmpfs at `/tmp/topup-scratch`,
- network namespace isolation (no outbound traffic by default; opt-in capability tool),
- CPU and wall-clock caps via `prlimit` or systemd-run scopes.

This is the same hygiene any LLM code-execution sandbox needs. Not novel.

**In-process safety is nil.** Bubblewrap blocks syscall-level escape. It doesn't catch `Obj.magic`, a misbehaving C stub, or any other path that segfaults the runtime or silently corrupts a binding. The design assumption is that *the toplevel process can die or become corrupt at any time*; checkpoint/replay (below) is how the session survives.

## Snapshots are phrase replay, not value Marshal

The obvious implementation of `checkpoint`/`restore` is `Marshal` of the current binding environment. It does not work: Marshal of closures produced by `Dynlink`ed code is unsupported and famously broken ([ocaml/ocaml#5215](https://github.com/ocaml/ocaml/issues/5215)), and the JIT scheme described above produces exactly those closures.

The realistic mechanism is **replay of the phrase history**, optionally combined with Marshal of values whose types are known to be Marshal-safe (no closures). `checkpoint(label)` records the phrase log up to that point; `restore(label)` spawns a fresh toplevel and replays. This is slower than value-Marshal would be, but it composes cleanly with the "process can die at any time" assumption from sandboxing: recovery is the same code path as branching.

## Session pooling and routing

A fresh toplevel is cheap. A toplevel with `Dynlink`-loaded libraries that mmap large datasets (a search index, a parsed corpus, a precomputed graph) is expensive — seconds to minutes of cold-cache I/O. Re-paying that cost on every `reset()` defeats the externalized-memory thesis.

`topup` should support **named, persistent sessions** with optional pre-warming on startup, plus a small pool of hot replicas for parallel exploration. Replay-based checkpoints (above) make branching cheap once a pool exists.

Pooling implies the server is stateful: a tool call has to address a specific live session. Two options — named sessions as an explicit tool parameter, or implicit via the client connection identity. The first is more honest about the statefulness; the second is friendlier to dumb clients. Likely both, with named taking precedence.

## Protocol: MCP, Jupyter, or both

The README's first draft committed to MCP. On reflection the toplevel core should be a **library**, with protocol frontends as thin shims:

- MCP for agent integration (the immediate target).
- Jupyter kernel protocol — already a near-perfect fit for the toplevel; streamed stdout, async display, interrupt, all native to the protocol.
- Direct CLI / pipe, for testing and humans.

MCP's request/response shape is awkward for long-running phrases and streamed stdout. Decide explicitly: in v1, eval is synchronous with a wall-clock cap and stdout returned at the end; streaming is deferred. Tools that need progress notifications (`cancel`, long batch eval) extend the protocol later.

## Relation to existing tools

### OCaml runtimes and toplevels

- **`ocaml`** (stock toplevel) — the runtime `topup` wraps. `Toploop.execute_phrase` is the core primitive.
- **`utop`** (Jérémie Dimino) — library-shaped, embeddable (`UTop_main.interact`), handles partial-input/multi-line phrase boundaries. Considered as a parser dependency, then rejected: LLMs send complete `eval` strings so the as-you-type completeness logic is wasted, and utop drags in Lwt + lambda-term + zed for code we wouldn't use. `topup` calls `compiler-libs` directly.
- **[`Down`](https://erratique.ch/software/down)** (Daniel Bünzli) — line editing, history, completion *for humans*. Inspiration for the name; orthogonal in function.
- **[`ocaml-jupyter`](https://github.com/akabe/ocaml-jupyter)** — Jupyter kernel wrapping the toplevel. Closest *protocol* analogue. The wedge over "fork ocaml-jupyter and add an MCP shim" is threefold: (a) checkpoint/restore via phrase replay for branching exploration, (b) `compile_to_binary` promotion, (c) native-JIT default (Jupyter is bytecode). Without those, the right move would in fact be to fork ocaml-jupyter.
- **[`ocaml_plugin`](https://github.com/janestreet/ocaml_plugin)** (Jane Street, archived) — automated compile-and-Dynlink of `.ml` sources. The JIT strategy for native-speed evaluation builds on this lineage.

### Existing MCP servers in the OCaml ecosystem

- **[`tmattio/ocaml-mcp`](https://github.com/tmattio/ocaml-mcp)** (Thibaut Mattio) — active, ~12 tools across dune, OCaml, and filesystem groups. Its `ocaml/eval` tool **is not a REPL**: each call spawns a fresh `ocaml -noprompt` subprocess, prepends `dune top` directives, pipes the source on stdin, and kills the subprocess. The project's own cram test demonstrates that `let x = 42` in one call leaves `x` unbound in the next. Bytecode, 5-second timeout, no env, no sessions, no sandbox. The philosophy is "deep integration with the language/tooling" — signatures, project structure, type-at-pos — with eval as a one-shot helper, not a working environment. **Complementary to `topup`, not competing**; the OCaml-side gap for a stateful REPL-as-MCP is real.
- **[`jonludlam/odoc-llm`](https://github.com/jonludlam/odoc-llm)** (Jon Ludlam, OxCaml Labs) — Python MCP server exposing package/module *semantic search* via LLM embeddings over odoc-generated markdown, plus type-search via sherlodoc. No eval, no sessions. Orthogonal to `topup`: it answers "which package should I use?", `topup` answers "evaluate this in the live environment."
- **Anil Madhavapeddy (`avsm`) — own MCP server retired.** Stated on the OCaml Discuss thread: "I hacked up an OCaml MCP implementation a few months ago … but I can retire that in favour of [tmattio's]." His current investment is Claude Code [skills/slash-commands](https://github.com/avsm/ocaml-claude-marketplace), not an MCP-exposed REPL.

### Stateful REPL-as-MCP in other languages

- **[`posit-dev/mcp-repl`](https://github.com/posit-dev/mcp-repl)** (Rust; R + Python) — the closest existing thing *in spirit*. Same headline pitch: keep the session open instead of forcing the agent to rebuild context. Two tools (`repl`, `repl_reset`); embedded-interpreter worker (knows precisely when idle, no stdout-heuristic polling); per-client sandbox policy via OS primitives (workspace-write + no network + memory guardrail); interrupt and reset via prefix bytes (``, ``); inline image content for plots; oversized-output handling via either pager or structured file bundle; reset escalation graceful → forceful → descendant-process scan. ~100 commits, prebuilt binaries, real product. **Lacks:** snapshot/restore, pooling, batched eval, env listing, compile-to-binary — none of which are very useful in dynamic languages anyway. `topup` should steal its operational design choices verbatim where they apply (interrupt prefix, reset escalation, oversized-output strategy).
- **[`kkokosa/repl-mcp`](https://github.com/kkokosa/repl-mcp)** — name collision; it's an MCP *client* CLI for testing servers, not a language REPL. Listed only to disambiguate.

### Where `topup` fits

The general "stateful REPL-as-MCP" pattern is validated. The OCaml-specific niche is empty: the one OCaml MCP server with an eval tool is deliberately stateless, and the `mcp-repl` analogue is R/Python-only. The combination `topup` claims — typed persistence + native JIT + replay checkpoints + compile-to-binary — is not on offer anywhere else, and the typed-recall argument is strictly stronger in OCaml than in any dynamic language.

## Out of scope (initial)

- Multi-user concurrent access. One LLM, one session, one toplevel process. Pool spawning is internal, not user-exposed.
- Distributed sessions (toplevel on a remote host, MCP server local). Possible later; first prove local value.
- Non-OCaml backends. Name is `topup`, scope is OCaml. A future `topup-py`, `topup-rs` could share protocol but not implementation.

## Decided

### Design

- **Error format:** structured `{phase: typecheck | runtime, location, message, related}`. LLMs parse JSON better than human-format compiler diagnostics.
- **Recovery / checkpoint mechanism:** phrase replay from a checkpoint log, not Marshal of values (issue #5215).
- **Phrase parsing:** call `compiler-libs` directly — `Parse.toplevel_phrase` in a loop with syntax-error recovery. utop is rejected because its as-you-type completeness logic is wasted on LLM-supplied complete strings, and Down is orthogonal (both are human-keyboard enhancers). Compiler-libs cross-version porting is the known cost.

### Phase-1 implementation choices

- **Scope:** `eval` / `env` / `lookup` / `reset` / `cancel`. Single session. Defer `load`, `checkpoint`/`restore`, `compile_to_binary`, pooling.
- **Code structure:** core library (`topup-core`, the `Session` API) + thin protocol shim (`topup-mcp`) as separate dune libraries from day 1. Future Jupyter / CLI frontends slot in beside `topup-mcp`.
- **MCP transport:** stdio only. One topup process per client; pre-warming happens during server startup before accepting tool calls. HTTP / daemon mode deferred.
- **MCP framework:** roll our own minimal layer — `initialize` + `tools/list` + `tools/call` + `notifications/cancelled` over stdio, ~500-800 LOC. Revisit when HTTP or richer features (resources, prompts) arrive.
- **OCaml floor:** 5.1+. Modern dune, modern compiler-libs, effect handlers available for user code.
- **Driver model:** bytecode driver + native `.cmxs` plugins (the `ocaml_plugin` shape). Driver runs as bytecode for mature `Toploop` reflection and easier `Dynlink` lifecycle; user phrases compile to native `.cmxs` for native-speed evaluation.

## Phase-1 planning

Open questions, partitioned by what blocks code-writing versus what blocks a useful release.

### Must answer before writing code

- **Stdout/stderr capture mechanism.** `Toploop` hooks vs. fd-level dup-and-pipe. Only the fd approach catches C-stub output and post-`eval` Lwt-fiber writes; the hooks approach is simpler but loses output the LLM may need. Lean toward fd-level.

### Must answer before phase-1 ships

- **Value representation.** Reuse `Toploop.print_value` with depth/length caps, or custom pretty-printer with elision? Custom is necessary for the oversized-output policy below.
- **Oversized output.** mcp-repl handles this with `--oversized-output {pager,files}` — either elide and offer pagination, or write to a structured bundle and return a file path. LLM context wrecks itself on multi-megabyte stdouts; the policy applies to `value_repr` too, not just `stdout` (a `Bigarray` pretty-prints arbitrarily large with empty stdout).
- **Idle detection under concurrency.** When has `eval` finished if the phrase spawns Lwt/Eio fibers? Default contract: `eval` returns when the top-level expression returns; background fibers are the user's problem and die at `reset`. Document loudly.
- **Phrase log persistence.** Per-session JSONL on disk, plain `.ml` concatenation, or in-memory only? In-memory is fine for v1 if `checkpoint` is deferred.
- **Testing strategy.** Unit tests on `Session`, integration tests via an in-process MCP client, optional LLM-in-the-loop smoke tests. First two block v1; third is operational.

### Pragmatic / consumer-side

- **First consumer's actual needs.** If a phase-1 consumer requires loading a large library from turn 1 (mmapped datasets, C-stub-heavy bindings), `load` and pre-warming become more load-bearing than the minimal-v1 cut admits.
- **Conversation with Thibaut Mattio.** Before phase-1: is his MCP stack compatible with topup's needs? Would he merge stateful-eval into `ocaml-mcp`, or is a separate server consuming his libraries the right path?

### Can defer (phase-2 or later)

- **Batched eval.** Per-phrase round-trip cost (~150 ms compile + protocol overhead) dominates for tight inner loops. `eval_batch([source; source; …])` is probably load-bearing at agent-loop rates.
- **`compile_to_binary` packaging.** Single `.ml` + a build command (simpler for one-shot deploys) vs. synthesized `dune-project` (necessary for non-stdlib deps).
- **Pre-warming policy.** Config file, idempotent "ensure-session" tool, or both?
- **Display hooks.** `#install_printer` works as-is — Toploop embeds the custom printer in the Outcometree before our hook fires, and `!Oprint.out_value` honours it. Open question is only *how* a session declares its standard printers without coupling `topup` to any particular library (e.g. a discovery mechanism or a per-package `topup_printers.ml`).
- **Per-client sandbox policy.** Differentiate by client identity (mcp-repl's Claude-vs-Codex split), or single configurable policy?
- **Pooling, checkpoint/replay, multi-protocol frontends, native JIT.** All in the design; none blocks v1.
