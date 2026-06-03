(** Default depth cap for [Toploop]'s value pretty-printer (Outcometree
    construction). Set by [configure_toploop]. *)
val max_depth : int ref

(** Default step (element) cap for [Toploop]'s value pretty-printer. *)
val max_steps : int ref

(** Default byte cap applied to the final rendered string of an eval
    result's [value_repr] / [type]. *)
val max_bytes : int ref

(** Install the current [max_depth] / [max_steps] into [Toploop]. Idempotent;
    call once after [Toploop.initialize_toplevel_env]. *)
val configure_toploop : unit -> unit

(** Truncate [s] to [~limit] bytes (default [!max_bytes]), appending an
    elision marker indicating the number of dropped bytes. *)
val truncate_bytes : ?limit:int -> string -> string
