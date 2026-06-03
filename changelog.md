# Changelog

Completed work, most recent at top. See `backlog.md` for pending work
and `.claude/skills/session-backlog/SKILL.md` for the workflow.

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
