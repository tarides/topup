(** Thin re-export of the [Toploop] symbols [Session] uses. Lets the
    same [Session] code link against either [compiler-libs.toplevel]
    (bytecode evaluation) or [compiler-libs.native-toplevel]
    (native-via-Dynlink evaluation). The implementation is provided by
    [topup_eval_byte] or [topup_eval_native]. *)

val initialize_toplevel_env : unit -> unit

val toplevel_env : Env.t ref

val parse_toplevel_phrase :
  (Lexing.lexbuf -> Parsetree.toplevel_phrase) ref

val print_out_phrase :
  (Format.formatter -> Outcometree.out_phrase -> unit) ref

val execute_phrase :
  bool -> Format.formatter -> Parsetree.toplevel_phrase -> bool

val max_printer_depth : int ref

val max_printer_steps : int ref

(** Initialize findlib's toplevel integration with the predicates
    appropriate for the active backend (["byte"] vs ["native"], plus
    ["toploop"]). Idempotent; safe to call after
    [initialize_toplevel_env]. *)
val init_findlib : unit -> unit

(** Add the [topup.runtime] package's .cmi directory to the
    typechecker's [Load_path] so [Session]'s prelude can resolve
    [Topup_runtime]. Must be called after each
    [initialize_toplevel_env] — the native backend's
    [Compmisc.init_path ()] wipes the path. Silently no-op if the
    package can't be found (test sandbox without findlib). *)
val prepare_topup_runtime : unit -> unit
