(** Promote the live session's phrase log into a standalone native
    binary via dune. v1 dumps the whole log verbatim — see
    [compile_to_binary]. *)

type result = {
  binary_path : string;  (** absolute path to the produced executable
                              on success; [""] on build failure. *)
  build_log : string;  (** combined stdout+stderr from [dune build];
                            useful inside-out when [ok = false]. *)
  ok : bool;  (** [true] iff [dune build] exited 0 and the binary
                  was copied to [binary_path]. *)
}

(** [compile_to_binary ~log_path ~entry ~out ~libraries] synthesises a
    minimal dune project at [out] from the recorded phrase log, builds
    it natively, and copies the resulting executable to [out/main.exe].

    - [log_path]: the [Session]'s phrase log; [None] (or a missing
      file) rejects with [Error _].
    - [entry]: name of a binding in scope at the end of the log.
      Validated against [[A-Za-z_][A-Za-z0-9_']*]. The synthesised
      wrapper is [let () = ignore (<entry> ())], so the binding must
      have type [unit -> _].
    - [out]: absolute directory path. Created on demand. If it
      already exists and contains files that aren't from a previous
      promote run (no [.topup-promote] marker), the call is refused
      to avoid clobbering unrelated content.
    - [libraries]: findlib package names. Each becomes a
      [(libraries ...)] entry in the synthesised dune file. The empty
      list means stdlib-only.

    Returns [Error msg] for input-level problems (missing log,
    invalid arg, unwritable [out]). A failed build returns
    [Ok { ok = false; build_log; binary_path = "" }] — the inputs
    were valid; dune itself rejected the project. *)
val compile_to_binary :
  log_path:string option ->
  entry:string ->
  out:string ->
  libraries:string list ->
  (result, string) Stdlib.result
