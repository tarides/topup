# LLM-in-the-loop smoke test — playbook

End-to-end exercise of the `topup` MCP server driven by a real model
through Claude Code. Walks the four-beat workflow named in the
original backlog item: define, use across turns, cancel, reset.
Operational, not CI-gated (DESIGN.md line 178: "First two block v1;
third is operational").

## What this validates

The **externalized-memory thesis** (DESIGN.md §"The externalized-memory
thesis"). The pitch — "turn N+1 just references `parsed_corpus` by
name; the toplevel holds the value, the model holds the name and type"
— is testable only by watching a real model do exactly that across
turns. Unit tests can't speak to it; in-process integration tests
fake the client. Beat 2 below is the load-bearing check.

The cancel and reset beats are easier — they verify operational
hygiene rather than the thesis. They are here because the backlog
item names them.

## Preconditions

The two failure modes that catch people are switch drift (the binary
that `.mcp.json` spawns is not the one you just rebuilt) and scope
shadowing (a Local/User MCP registration overrides the project one).
Walk these in order before touching the playbook proper.

1. **Switch alignment.** `.mcp.json` at the repo root pins the
   binary by **absolute path**, typically
   `~/.opam/<switch>/bin/topup`. `opam reinstall topup --working-dir
   --yes` installs into whichever switch is *currently active* —
   which may be a local `_opam/` switch at the repo root, a sibling
   project's switch you forgot to deactivate, or the global default.
   These can disagree silently.

   Confirm they match:
   ```
   opam var switch                                # active switch
   opam var bin                                   # where reinstall lands
   grep -E '"command"' .mcp.json                  # what claude spawns
   ```
   The directory in `opam var bin` must be the prefix of the
   `command` path in `.mcp.json`. If not, fix one of:
   - `opam switch <name>` to activate the switch named in
     `.mcp.json`, then reinstall.
   - Edit `.mcp.json` to point at `$(opam var bin)/topup` for the
     switch you actually want to develop against.
   - If the repo has a local switch you didn't intend, deactivate it
     (`opam switch <global-name>` from this directory).

2. **Build & install** (now that the switch is right):
   ```
   opam exec -- dune build @all
   opam reinstall topup --working-dir --yes
   ```

3. **MCP scope.** `claude mcp get topup` should report
   `Scope: Project config (shared via .mcp.json)`. A Local or User
   scope **shadows** the project one — remove it
   (`claude mcp remove topup -s local` / `-s user`) per CLAUDE.md →
   "MCP / Claude Code integration gotchas". The command does not
   print the binary path; for that, read `.mcp.json` directly.

4. **Fully restart Claude Code** (`/quit`, then re-launch). A
   `Status: ✓ Connected` line in `claude mcp get topup` only means
   *some* binary is running; it does not mean the *freshly rebuilt*
   one is. `/mcp` Reconnect does not re-spawn the binary either.
   Same gotcha in CLAUDE.md.

5. **Optional cleanup** so the session starts blank:
   ```
   rm -f  ~/.topup/history.ml
   rm -rf ~/.topup/spill
   ```
   Not required for correctness (the playbook starts with `#reset`
   anyway), but makes the replay log cleaner.

6. **`/caml` skill enabled** in the project's Claude Code settings.
   Should be on by default for this repo via
   `.claude/settings.local.json`.

## Procedure

Each beat is one turn (or two where noted). Tester types the prompt
in **bold**; Claude is expected to respond with the `/caml`
invocation shown after "expected call:" and a response matching
"expected response shape". Capture the actual transcript into
`test/smoke/replay_<YYYY-MM-DD>.md` as the run happens.

### Beat 0 — Clean slate (sanity)

**"`/caml #reset`"**

- Expected call: `/caml #reset`
- Expected response: `ok`

Confirms the server is reachable before doing anything that could be
mistaken for an externalized-memory effect.

### Beat 1 — Define

**"Use the OCaml toplevel to compute the first 1000 prime numbers via
a `Seq`-based generator and keep them bound for later. Don't paste
the list back to me."**

- Expected call: a `/caml let primes = … ;;` (or a two-step
  `is_prime` then `primes` sequence) that ends with a
  `primes : int list` binding of length 1000, built through `Seq`.
  A typical shape:
  ```ocaml
  let is_prime n =
    let rec aux k = k * k > n || (n mod k <> 0 && aux (k + 1)) in
    n >= 2 && aux 2

  let primes =
    Seq.ints 2 |> Seq.filter is_prime |> Seq.take 1000 |> List.of_seq
  ```
  The classic Seq-pipeline sieve is acceptable too:
  ```ocaml
  let primes =
    let rec sieve s () = match s () with
      | Seq.Nil -> Seq.Nil
      | Seq.Cons (p, rest) ->
          Seq.Cons (p, sieve (Seq.filter (fun n -> n mod p <> 0) rest))
    in
    sieve (Seq.ints 2) |> Seq.take 1000 |> List.of_seq
  ```
  What matters is that `primes : int list` of length 1000 ends up
  bound; the algorithm just has to be honest.
- Expected response shape: a `value : type` line with `int list`
  and *not* the full list pasted back. If the inline representation
  hits `Pretty.max_bytes` (8 KiB) the response will truncate with
  the `…[+N bytes; full at <path>]` marker — that is fine and
  intended; the binding is what matters.
- Verification (same turn or next): **"`/caml #env`"** should
  include a line `primes : int list` (and `is_prime : int -> bool`
  if the model defined it separately).

### Beat 2 — Use across a turn (the thesis check)

**Start a fresh-feeling prompt — do not refer back to "those
primes". Use a question that requires the binding without naming it
verbatim:**

**"What is the largest of the first 1000 primes?"**

- Expected call: something like
  `/caml List.fold_left max 0 primes;;` or
  `/caml List.nth primes 999;;`. The load-bearing observation is
  that the model **references `primes` by name** — it does not
  recompute the list and it does not ask the tester to paste it.
- Expected response: a single `int : int` line (the actual prime is
  7919 for the first 1000; flag if it disagrees materially).
- **Thesis assertion:** the call references the binding. If the
  model instead recomputes from scratch, the thesis is failing in
  practice for this model on this prompt; record the actual behaviour
  in the replay log and open a backlog item rather than papering
  over it.

A second use-across-turns probe is optional but cheap:

**"And the average, as an int?"**

- Expected: `/caml List.fold_left (+) 0 primes / List.length primes;;`
  or equivalent. Same name-reuse signal.

### Beat 3 — Cancel

**"Run an evaluation that won't terminate, then cancel it. Use
either a 2-second timeout or `#cancel` from a second turn —
whichever you'd reach for."**

- Expected call A (preferred): `/caml --timeout=2 let rec loop () = loop () in loop ();;`
  Response should contain a `Sys.Break` / "evaluation timed out"
  shape from the watchdog.
- Expected call B: `/caml while true do () done;;` followed in the
  next turn by `/caml #cancel`. The first call blocks until cancel
  arrives; the cancel responds `ok`.
- Follow-up sanity: **"`/caml 1+1;;`"** must return `2 : int`. This
  is the real assertion — the toplevel survived the interrupt.

### Beat 4 — Reset

**"`/caml #reset`, then confirm `primes` is gone."**

- Expected calls (in any order Claude reaches for them):
  - `/caml #reset` → `ok`
  - `/caml #lookup primes` → `unbound: primes`
  - `/caml #env` → empty (or, in the skill's phrasing, "no user
    bindings; suggest `/caml #env --all` to also see stdlib")

## Success criteria

- Beats 0, 1, 3, 4 produce the responses listed.
- Beat 2's expected call references `primes` by name. **This is the
  thesis assertion.** Anything else (recomputation, paste-back, ask
  the tester) is a finding worth recording — capture verbatim and
  open a backlog item.

One failure does not invalidate the v1 cut (this test is
operational), but every failure deserves a written verdict in the
replay log. Do not retry until green silently.

## After the run

Save the captured transcript to
`test/smoke/replay_<YYYY-MM-DD>.md` and commit it alongside any
findings. The first such replay is the artifact that proves the
playbook ever passed end-to-end; subsequent replays are optional but
useful when the model, the binary, or the `/caml` skill changes.
