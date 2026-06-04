# topup

A persistent OCaml toplevel exposed as an MCP server. Lets an LLM keep
typed working memory across conversation turns.

## Why

LLM coding assistants in typed compiled languages pay two recurring costs:
a build cycle for every idea, and re-derivation (or re-serialization)
of intermediate values turn after turn. `topup` cuts both: phrases run
inside a long-lived toplevel, and bindings persist. The model carries
only **names and types** in its context; the toplevel holds the values.
The OCaml type system makes that recall sound — the compiler catches a
stale or mistyped reference before evaluation.

See [DESIGN.md](DESIGN.md) for the longer rationale, the phase-2 roadmap,
and how `topup` relates to neighbouring projects.

## Install

Requires OCaml 5.1+ and dune.

```
opam exec -- dune build @all
opam exec -- dune runtest
```

The binary lands at `_build/default/bin/main.bc.exe`.

Register with Claude Code (user-scoped):

```
claude mcp add topup $(pwd)/_build/default/bin/main.bc.exe
```

Or drop a project-local `.mcp.json` at the repo root:

```json
{
  "mcpServers": {
    "topup": {
      "command": "/absolute/path/to/_build/default/bin/main.bc.exe"
    }
  }
}
```

Restart Claude Code (or run `/mcp` → Reconnect) so the new server is picked up.

### Optional: the `/caml` slash command

This repo ships a small Claude Code skill that wraps the five MCP
tools behind `/caml`. It is project-scoped (lives under
`.claude/skills/caml/`) so it activates automatically when Claude
Code is run inside a `topup` checkout. To use it from anywhere,
copy it to your user-scope skills directory:

```
mkdir -p ~/.claude/skills/caml
cp .claude/skills/caml/SKILL.md ~/.claude/skills/caml/SKILL.md
```

Then `/caml 1 + 1;;`, `/caml #env`, `/caml #reset`, etc. work from
any project. The skill calls `mcp__topup__*` directly, so the
`topup` MCP server must still be registered.

## Tools

| Tool | Effect |
|------|--------|
| `eval(source, timeout?)` | Evaluate one or more phrases. Returns `{value_repr, type, stdout, stderr, warnings, error}`. |
| `env(filter?)` | List current bindings as `[(name, type, location, preview?)]`. |
| `lookup(name)` | Inspect a single binding. |
| `reset()` | Discard the toplevel environment. |
| `cancel()` | Interrupt the running evaluation. |

## Example

```
eval   { source: "let xs = List.init 100 (fun i -> i * i);;" }
       → value_repr: "[0; 1; 4; 9; …]", type: "int list"

eval   { source: "List.length xs;;" }
       → value_repr: "100", type: "int"

env    { filter: "xs" }
       → [{ name: "xs", type: "int list", … }]

eval   { source: "let rec spin n = spin n;;", timeout: 0.3 }
       → error: { phase: "runtime", message: "evaluation timed out" }
```

## Status

Phase-1 MVP: bytecode toplevel, single session, MCP over stdio
(default) or a Unix domain socket (`topup --socket <path>` — one
client at a time, state persists across connections). `load`,
`checkpoint`/`restore`, native-JIT, pooling, and `compile_to_binary`
are deferred — see DESIGN.md.
