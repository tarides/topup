# AI usage disclosure

`topup` was developed in close collaboration with Anthropic's Claude
(Opus 4.7, driven via Claude Code as the MCP client and harness). At
the time of writing, 32 of 33 commits carry a `Co-Authored-By: Claude
Opus 4.7 (1M context) <noreply@anthropic.com>` trailer; the first
design-sketch commit predates that workflow. `git log --format="%B" |
grep "Co-Authored-By: Claude"` is the durable record.

The collaboration is intentional. `topup` is itself a tool for
LLM-driven OCaml workflows, so building it with such a workflow is
both the natural fit and an ongoing test of the externalized-memory
thesis DESIGN.md argues for.

## What that means concretely

- **Authorship and responsibility.** Cuihtlauac ALVARADO is the sole
  human author and the responsible party for what is shipped. Every
  Claude-generated change was read and either accepted, edited, or
  discarded by a human before landing on `main`. Design errors and
  bugs are his.

- **Workflow artefacts.** `CLAUDE.md`, `backlog.md`, `changelog.md`,
  and `.claude/skills/caml/SKILL.md` are part of how the
  human–Claude collaboration is structured. They are operational
  notes for the maintainer, not contractual documents for external
  contributors.

- **No runtime LLM dependency.** Running the `topup` binary does
  **not** invoke any LLM. `topup` is the OCaml-side endpoint that a
  separate MCP client (Claude Code, or any other) calls into. The
  AI involvement is in development, not in the deployed artefact;
  the binary has no network calls to any model provider.

## For downstream users

The ISC license (see `LICENSE`) is unchanged and unaffected by the
above. The same warranty disclaimer applies regardless of how the
code was authored. Treat `topup` as you would any other open-source
OCaml package: read what you intend to run.

## For contributors

If you used an LLM to write or shape a pull request, you are
encouraged to record it with a `Co-Authored-By` trailer in the
style above; it matches the existing history and helps future
provenance audits. It is not required. What is required is that the
code in your PR is something you understand and stand behind — same
as any other contribution.
