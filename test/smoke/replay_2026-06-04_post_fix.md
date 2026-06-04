# Replay log — 2026-06-04 (post-fix)

Second end-to-end run of `test/smoke/llm_playbook.md`, performed the
same day as the first run after the Beat-1 crash bug it surfaced was
fixed in the same session. Model: Opus 4.7 (1M context), Claude Code
v2.1.143. Binary reinstalled from `main` with the fix applied
(`lib/topup/session.ml` + `lib/mcp/tools.ml`); Claude Code fully
restarted. All four beats reached their expected end-state; the
crash from the earlier replay is closed.

## Beat 0 — Clean slate

```
❯ /caml #reset
● ok
```

**Verdict: pass.**

## Beat 1 — Define

The first paste was deliberately the verbatim crash repro from
`replay_2026-06-04.md` — duplicated `let primes = let primes = …`
head followed by a Seq-sieve body with no `in <body>` for the inner
binding. Where the unfixed binary exited the process, the patched
binary returned a structured parse error:

```
❯ /caml let primes = let primes =
  let rec sieve s () = match s () with
    | Seq.Nil -> Seq.Nil
    | Seq.Cons (p, rest) ->
        Seq.Cons (p, sieve (Seq.filter (fun n -> n mod p <> 0) rest))
  in
  sieve (Seq.ints 2) |> Seq.take 1000 |> List.of_seq

● typecheck: Syntax error
  <eval>:7:52-54
```

No `Connection closed` message. The session stayed alive for the
remaining beats. Three subsequent retries with model-side typos —
`sieve` referenced before bound, Seq.Cons / Seq.Nil branch order
issues — each returned a clean typecheck error and the session kept
serving. Final working paste:

```
❯ /caml let primes = let rec loop s () = match s () with
    Seq.Cons (p, s) ->
      Seq.Cons (p, loop (Seq.filter (fun n -> n mod p <> 0) s))
  | Seq.Nil -> Seq.Nil in
  loop (Seq.ints 2) |> Seq.take 1000 |> List.of_seq

● [2; 3; 5; 7; 11; 13; 17; 19; 23; …; 1213; 1217; ...] : int list
```

**Verdict: pass. The closed bug stays closed; subsequent typo
recovery is what the structured-error contract is for.**

## Beat 2 — Use across a turn (the thesis check)

Three natural-language questions in succession, none referencing
`primes` by name, all answered by reaching for the binding via MCP
with no recomputation and no paste-back:

```
❯ what's the greatest prime smaller than 1000
  Called topup
● 997

❯ what's the 1000th prime?
  Called topup
● 7919

❯ what the widest gap between two primes among the first 1000
  Called topup
● 34, between 1327 and 1361
```

Underlying calls (visible via the tool-call expand):

```
/caml List.fold_left (fun acc p -> if p < 1000 then p else acc) 0 primes;;
/caml List.nth primes 999;;
/caml (* fold to (gap, a, b) over zipped pairs *)
```

**Verdict: pass on three independent prompts. Thesis holds across a
broader probe than the scripted single question; the playbook's
recommended prompt is now one of several known-good shapes.**

## Beat 3 — Cancel

```
❯ /caml --timeout=2 let rec loop () = loop () in loop ()
● runtime: evaluation timed out

❯ /caml 1+1
● 2 : int
```

**Verdict: pass. Watchdog fired at ~2 s, toplevel survived, next
eval returned `2 : int` as required.**

## Beat 4 — Reset

```
❯ /caml #reset
● ok

❯ /caml #lookup primes
● unbound: primes

❯ /caml #env
● No user bindings. Try /caml #env --all to also see stdlib.
```

**Verdict: pass.**

## Findings

1. **Beat-1 crash from the earlier replay is closed.** The verbatim
   duplicated-`let` paste that exited the process on
   `replay_2026-06-04.md` now returns a `typecheck` error with
   location and a non-empty message; subsequent requests on the same
   session keep working. The fix lives in two places:
   `lib/topup/session.ml` (parse-exception path now routes through
   `Error.of_exn`, parallel to the existing typecheck / runtime
   handling) and `lib/mcp/tools.ml` (defensive `try/with` around the
   dispatch body so any future uncaught tool exception becomes an
   `isError:true` text result rather than a process exit). A
   regression stanza in `test/test_session.ml` pins the behaviour
   with the verbatim crash input.

2. **Model-side paste fragility is independent of topup.** Three
   retries on Beat 1 stemmed from typos the model emitted (wrong
   recursive-call name, swapped pattern branches). Each surfaced
   cleanly via the structured-error path; none affected session
   liveness. The earlier replay reported the same operator-side
   artifact as a paste/control-character issue.

3. **Beat 2 was exercised with three free-form prompts instead of
   the scripted single one.** All three asked questions that
   required the binding without naming it verbatim; all three were
   resolved by name-referenced calls into the live session. The
   thesis holds across a wider probe than the playbook prescribes.

## Verdict

Playbook passes end-to-end with the patched binary. The
"`MCP error: Connection closed`" failure mode from
`replay_2026-06-04.md` is gone for the input that produced it and
for the broader class of parser-time exceptions it represented.
