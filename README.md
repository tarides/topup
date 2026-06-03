# topup

> An OCaml toplevel exposed as an MCP server, designed for LLM-driven interactive workflows.

**Status:** design sketch. No code yet.

## Name

Three readings, all intentional:

- **top** — from "toplevel", OCaml's REPL.
- **up** — pairs with Daniel Bünzli's [`Down`](https://erratique.ch/software/down). `Down` enhances the toplevel *for humans at a keyboard*. `topup` exposes the toplevel *upward*, to a higher-level consumer — an LLM, an agent, a notebook kernel.
- **top up** — what you do to a phone, a fuel tank, or a stash of working memory. `topup` is durable typed scratch space for an LLM whose context window is bounded.

## Motivation

LLM-driven coding assistants run into three connected problems whenever they work in a typed compiled language:

1. **Iteration latency.** Each idea costs a build cycle: edit, dune build, run, read output. The model burns wall-clock time and tokens on rebuilds that the toplevel would skip.
2. **Type-feedback latency.** The model frequently writes ill-typed code that the compiler would reject in 50 ms. Without an interactive evaluator, that signal arrives only after a full build.
3. **Working-memory pressure.** Intermediate values — a parsed dataset, an expensive index, a partially-explored data structure — either get re-derived every turn (wasting tokens and time) or get serialized into the context window (wasting tokens). Neither is right.

OCaml already has the runtime that solves all three: the toplevel. Stock `ocaml`, `utop`, and the `Toploop` library evaluate phrases incrementally against a persistent typed environment, with type-checking before every evaluation and durable bindings across turns. `topup` wraps that runtime as an MCP server so an LLM can use it directly.

## What the LLM gets

A small set of MCP tools, sufficient to use a long-lived toplevel as the model's working environment:

| Tool | Effect |
|------|--------|
| `eval(source)` | Evaluate one or more OCaml phrases. Returns `{value_repr, type, stdout, warnings, error}`. |
| `env()` | List current bindings as `[(name, type)]`. The model's RAG-over-self primitive. |
| `lookup(name)` | Inspect one binding: type, brief value preview, source location if available. |
| `load(path)` | `Dynlink` a `.cmxs` plugin (libraries the model wants in scope). |
| `reset()` | Discard the current session and start fresh. |
| `snapshot(label)` / `restore(label)` | Save and restore a named session state — for replay, A/B exploration, recovery from a poisoned binding. |
| `compile_to_binary(entry, out)` | Promote a validated query: serialize relevant phrases + freeze the binding environment into a standalone `.ml` file, build with `dune`, emit a native ELF for production runs. |

The Phase-2 promotion via `compile_to_binary` is what keeps `topup` honest. The toplevel is for *exploration and refinement*; once a query is stable, it leaves the toplevel and runs as a normal native binary — same source, no toplevel dependency at runtime.

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

## Session pooling

A fresh toplevel is cheap. A toplevel with `Dynlink`-loaded libraries that mmap large datasets (e.g. libblocksci + tx_data.dat) is expensive — seconds to minutes of cold-cache I/O. Re-paying that cost on every `reset()` defeats the externalized-memory thesis.

`topup` should support **named, persistent sessions** with optional pre-warming on startup, plus a small pool of hot replicas for parallel exploration. Snapshot/restore (see tool table) makes branching cheap.

## Relation to existing tools

- **`ocaml`** (stock toplevel) — the runtime `topup` wraps. `Toploop.execute_phrase` is the core primitive.
- **`utop`** (Jérémie Dimino) — library-shaped, embeddable (`UTop_main.interact`), handles partial-input/multi-line phrase boundaries. Better starting point than stock `ocaml`.
- **[`Down`](https://erratique.ch/software/down)** (Daniel Bünzli) — line editing, history, completion *for humans*. Inspiration for the name; orthogonal in function.
- **[`ocaml-jupyter`](https://github.com/akabe/ocaml-jupyter)** — Jupyter kernel wrapping the toplevel. Closest existing analogue; the kernel protocol is morally what MCP would be. `topup`'s MCP shim is largely a protocol translation from Jupyter's request/reply pattern.
- **[`ocaml_plugin`](https://github.com/janestreet/ocaml_plugin)** (Jane Street, archived) — automated compile-and-Dynlink of `.ml` sources. The JIT strategy for native-speed evaluation builds on this lineage.

## Out of scope (initial)

- Multi-user concurrent access. One LLM, one session, one toplevel process. Pool spawning is internal, not user-exposed.
- Distributed sessions (toplevel on a remote host, MCP server local). Possible later; first prove local value.
- Non-OCaml backends. Name is `topup`, scope is OCaml. A future `topup-py`, `topup-rs` could share protocol but not implementation.

## Consumers

The first concrete consumer is BlockSci's Tier-2 interactive query UX — see `~/Projects/BlockSci/PLAN_MOBILE_CODE.md`. BlockSci is *not* the only intended consumer; Lonnrot, blocksci-datalog, and any LLM-OCaml workflow are candidates. Keeping `topup` BlockSci-agnostic is a deliberate design choice.

## Open questions

- Phrase boundary detection on streaming input — adopt utop's parser or do it ad hoc?
- Snapshot format — Marshal-based, with caveats about Dynlinked-code closures ([ocaml/ocaml#5215](https://github.com/ocaml/ocaml/issues/5215))?
- Cost of MCP tool round-trips for one-line phrases — does the model want a batched-eval tool, or does the protocol overhead not matter at human scale?
- Error formatting: raw compiler output vs. a structured `{phase: typecheck|runtime, location, message}` shape.
- Does `compile_to_binary` need dune-project synthesis or can it emit a single `.ml` + a build command?
