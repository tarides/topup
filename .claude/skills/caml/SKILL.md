---
name: caml
description: Evaluate OCaml in the persistent topup toplevel. Triggered when the user types `/caml <source>`. The args are one or more OCaml phrases to evaluate against the long-lived session held by the topup MCP server; bindings persist across calls.
---

The user invoked `/caml <args>`. The `<args>` portion is OCaml source to
evaluate.

## How to handle it

1. Treat `<args>` as the source verbatim. If it does not already end
   with `;;`, append `;;` so each phrase is terminated.
2. If `<args>` begins with `--timeout=<seconds>` (a positive number),
   strip that prefix and pass the value as the `timeout` argument to
   the eval tool. Otherwise omit `timeout`.
3. Call `mcp__topup__eval` with `source` set to the prepared string
   (and `timeout` if extracted).
4. Show the result tersely. Concretely:
   - If `error` is non-null: print `error.phase`, `error.message`, and
     — if `error.location` is non-null — `file:line:col_start-col_end`.
     Then stop.
   - Otherwise, if `stdout` is non-empty, print it as a fenced block.
   - Then print `<value_repr> : <type>` on a single line when both are
     non-null. If only `type` is non-null (e.g. a `let` binding with no
     printable value), print `: <type>`.
   - Mention `stderr` only if it is non-empty.

## Hard rules

- Do not editorialise the OCaml. Pass the user's source through
  unchanged except for the `;;` terminator and timeout extraction.
- Do not call other tools (Bash, Read, Edit, etc.) — this skill is a
  thin wrapper around `mcp__topup__eval`.
- If the topup MCP server is not connected, say so and tell the user
  to run `/mcp` → Reconnect, or
  `claude mcp add topup <path>/_build/default/bin/main.bc.exe`.

## Companion tools

`topup` also exposes `mcp__topup__env`, `mcp__topup__lookup`,
`mcp__topup__reset`, and `mcp__topup__cancel`. Use them when the user
asks to list bindings, inspect one, drop session state, or interrupt a
runaway evaluation — but only when the user asks explicitly; this
skill itself is just `eval`.
