---
name: caml
description: Evaluate OCaml in the persistent topup toplevel, or call one of the topup MCP directives. Triggered when the user types `/caml <args>`. Bare source is evaluated; args starting with a `#<directive>` invoke env / lookup / reset / cancel. Bindings persist across calls.
---

The user invoked `/caml <args>`. Parse `<args>` and dispatch to the
matching topup MCP tool.

## Directive parsing

Strip leading whitespace from `<args>`. Then look at the first token.

| First token | Action | Tool | Arguments |
|-------------|--------|------|-----------|
| `#env`      | List bindings    | `mcp__topup__env`    | rest of line, if non-empty, becomes `filter` |
| `#lookup`   | Inspect a binding | `mcp__topup__lookup` | rest of line is `name` (required; if missing, ask the user) |
| `#reset`    | Discard environment | `mcp__topup__reset`  | none |
| `#cancel`   | Interrupt running eval | `mcp__topup__cancel` | none |
| anything else | Evaluate as OCaml | `mcp__topup__eval`   | see below |

The `#`-directives mirror OCaml's toplevel-directive convention
(`#use`, `#load`, `#trace`) and are reserved at the start of the
argument line only — `#` appearing inside OCaml source (e.g.
`module M = struct type t = #foo end`) is never reinterpreted.

## Eval path

When dispatching to `mcp__topup__eval`:

1. If the source begins with `--timeout=<seconds>` (a positive
   number), strip that prefix and pass the value as the `timeout`
   argument. Otherwise omit `timeout`.
2. If the source does not already end with `;;`, append `;;`.
3. Call `mcp__topup__eval` with the prepared `source` (and `timeout`
   when extracted).

## Result formatting

For every tool, keep the response terse — the user is at a REPL.

### eval

- If `error` is non-null: print `<phase>: <message>` and, when
  `error.location` is non-null, `file:line:col_start-col_end`. Stop.
- Else, if `stdout` is non-empty, show it as a fenced block.
- Then print `<value_repr> : <type>` on a single line if both are
  non-null; print `: <type>` alone if only the type is non-null
  (e.g. a `let` binding with no printable value).
- Mention `stderr` only when non-empty.

### env

- Print one line per binding: `<name> : <type>`.
- If the result list is empty, say so explicitly.
- Skip the `location` and `preview` fields unless the user asks for
  them — the table view is the point.

### lookup

- If the response is `null`, say `unbound: <name>`.
- Otherwise print `<name> : <type>` and, when `location.file` is not
  `<eval>`, append `(defined at <file>:<line>)`.

### reset / cancel

- Print `ok` on success. Nothing else.

## Hard rules

- Do not editorialise the OCaml. Pass user source through unchanged
  except for the `;;` terminator and timeout extraction.
- Do not call other tools (Bash, Read, Edit, etc.) — this skill is a
  thin wrapper around the five `mcp__topup__*` tools.
- If the topup MCP server is not connected, say so and tell the user
  to run `/mcp` → Reconnect, or
  `claude mcp add topup <path>/_build/default/bin/main.bc.exe`.
