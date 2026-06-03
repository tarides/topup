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

A small set of tools, sufficient to use a long-lived toplevel as the model's working environment:

| Tool | Effect |
|------|--------|
| `eval(source)` | Evaluate one or more OCaml phrases. Returns `{value_repr, type, stdout, warnings, error}`. Errors are structured: `{phase: typecheck \| runtime, location, message, related}`. |
| `env(filter?)` | List current bindings as `[(name, type)]`. Filters by recency, type prefix, or namespace — unfiltered output doesn't scale past a few dozen bindings. The model's RAG-over-self primitive. |
| `lookup(name)` | Inspect one binding: type, brief value preview, source location if available. |
| `load(path)` | `Dynlink` a `.cmxs` plugin (libraries the model wants in scope). |
| `cancel()` | Interrupt the currently-running phrase. Also exposed as an input-prefix byte (cf. mcp-repl's ``), so the model can interrupt without a separate tool round-trip. Wall-clock caps catch the model that forgets; this catches the one that doesn't. |
| `reset()` | Discard the current session and start fresh. Escalates graceful → forceful → descendant-process scan (mcp-repl's approach; necessary when a Dynlinked C stub leaves zombie threads). |
| `checkpoint(label)` / `restore(label)` | Save and restore a named session state via **phrase replay**, not value Marshal. See "Snapshots" below for why. |
| `compile_to_binary(entry, out)` | Promote a validated query: serialize phrases reachable from `entry` + freeze the binding environment into a standalone `.ml` file, build with `dune`, emit a native ELF for production runs. |

The Phase-2 promotion via `compile_to_binary` is what keeps `topup` honest. The toplevel is for *exploration and refinement*; once a query is stable, it leaves the toplevel and runs as a normal native binary — same source, no toplevel dependency at runtime.

Selecting which phrases enter `compile_to_binary` is a real design choice, not an implementation detail: source-level reachability from `entry` is the default; user-curation is the escape hatch. Naive "serialize all phrases the session ever evaluated" produces broken builds.

## The externalized-memory thesis

This is the part of the design that justifies `topup` versus just-use-utop.

A typical LLM coding loop:

```
turn N:   model evaluates `let big_txs = ... (* expensive *)`
turn N+1: model wants to refer to `big_txs`
          → must either re-derive it (slow, wasteful) or
            paste its serialized form into context (token-expensive)
```

With `topup`, turn N+1 just references `big_txs` by name. The toplevel holds the value; the model holds the *name and type*. Cost: one symbol in the context, instead of N kilobytes of data. The OCaml type system makes this recall *sound* — the model can't accidentally use `big_txs` somewhere a `block list` is expected; the compiler will catch it before evaluation.

This inverts the usual pattern (model carries state in context, tool is stateless). Here the tool carries state, the model carries only names + types + intent. Analogous to Claude Code's memory files but typed, programmatic, and live.

**The general pattern isn't novel.** Posit's [`mcp-repl`](https://github.com/posit-dev/mcp-repl) (R + Python) ships a stateful REPL-as-MCP with explicitly the same pitch — "a shell tool keeps forcing the agent to rebuild context; mcp-repl keeps the session open instead." The persistence-beats-stateless argument is in the air. What's specific to `topup` is the combination that the dynamic-language variants can't offer: typed recall (the type system makes name reuse *sound*), native-speed evaluation, and a promotion path to a standalone binary. See "Relation to existing tools" below.

**Honest caveat.** A type signature for a record with 47 fields tells the model the *type*, not what's *in* `big_txs`. In practice the model will call `lookup` often, partially refilling context with previews. The thesis trades "values inlined in context" for "many cheap typed lookups," not for free recall. That's still a big win — `lookup` returns *exactly* what the model asks for, on demand — but it's not magic.

## Native-speed evaluation

Stock `ocaml` is bytecode. For most interactive work that's fine, but for LLM-driven workloads that may walk large datasets (e.g. blockchain analyses, parsing big logs), bytecode evaluation is too slow.

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

A fresh toplevel is cheap. A toplevel with `Dynlink`-loaded libraries that mmap large datasets (e.g. libblocksci + tx_data.dat) is expensive — seconds to minutes of cold-cache I/O. Re-paying that cost on every `reset()` defeats the externalized-memory thesis.

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
- **`utop`** (Jérémie Dimino) — library-shaped, embeddable (`UTop_main.interact`), handles partial-input/multi-line phrase boundaries. Better starting point than stock `ocaml`.
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

## Consumers

The first concrete consumer is BlockSci's Tier-2 interactive query UX — see `~/Projects/BlockSci/PLAN_MOBILE_CODE.md`. BlockSci is *not* the only intended consumer; Lonnrot, blocksci-datalog, and any LLM-OCaml workflow are candidates. Keeping `topup` BlockSci-agnostic is a deliberate design choice.

## Decided

- **Phrase boundary detection:** adopt utop's parser. The ad-hoc alternative reinvents a solved problem.
- **Error format:** structured `{phase: typecheck | runtime, location, message, related}`. LLMs parse JSON better than human-format compiler diagnostics.
- **Recovery / checkpoint mechanism:** phrase replay from a checkpoint log, not Marshal of values (issue #5215).

## Open questions

- **Batched eval.** Per-phrase round-trip cost (~150 ms compile + protocol overhead) dominates for tight inner loops where the model writes 5–10 short phrases. A `eval_batch([source; source; …])` tool is probably load-bearing for the latency thesis at agent-loop rates, not a nice-to-have.
- **`compile_to_binary` packaging.** Single `.ml` + a build command, or a synthesized `dune-project`? The single-file form is simpler for one-shot deploys; the dune-project form is necessary as soon as the query depends on libraries beyond the stdlib.
- **Pre-warming policy.** Which sessions get pre-warmed at startup, and how is the configuration expressed — a config file, an idempotent "ensure-session" tool, or both?
- **Display hooks.** Custom printers (à la `#install_printer`) for domain types (e.g. BlockSci's `tx`, `block`) are how the toplevel becomes ergonomic for a specific consumer. How does a session declare its printers without coupling `topup` to any particular library?
- **Oversized output.** mcp-repl handles this with `--oversized-output {pager,files}` — either elide and offer pagination, or write to a structured bundle and return a file path. LLM context wrecks itself on multi-megabyte stdouts; `topup` needs a policy from day 1. The OCaml-specific twist: a `value_repr` for a `Bigarray` or a deep tree can be arbitrarily large even when stdout is empty, so the policy applies to the `value_repr` field too, not just `stdout`.
- **Per-client sandbox policy.** mcp-repl ships different defaults for Claude vs. Codex (the latter inherits the host sandbox, the former gets workspace-write). Should `topup` differentiate by client identity, or expose a single configurable policy and let the operator set it?
- **Idle detection.** mcp-repl's embedded-interpreter design lets it know precisely when the interpreter is idle, sidestepping the "did the prompt come back?" heuristic. `topup`'s Dynlink scheme inherits this property (the `Dynlink.loadfile` call returns when evaluation completes); worth confirming this holds for phrases that spawn `Lwt`/`Eio` fibers — what counts as "done" when there are background fibers still scheduled?
