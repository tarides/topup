(** Default depth cap for [Toploop]'s value pretty-printer (Outcometree
    construction). Set by [configure_toploop]. *)
val max_depth : int ref

(** Default step (element) cap for [Toploop]'s value pretty-printer. *)
val max_steps : int ref

(** Default byte cap applied to the inline [value_repr] of an eval
    result. Content beyond this length is replaced with an elision
    marker; if a [Spill.t] is in scope, the full value is also written
    to a spill file. *)
val max_bytes : int ref

(** Default byte cap applied to the inline [stdout] of an eval result.
    Same overflow handling as [max_bytes]. *)
val max_stdout_bytes : int ref

(** Default byte cap applied to the inline [stderr] of an eval result.
    Same overflow handling as [max_bytes]. *)
val max_stderr_bytes : int ref

(** Hard ceiling on the size of an individual spill file. Content beyond
    this length is dropped with a trailing elision marker so a runaway
    print loop does not fill the disk. *)
val max_spill_bytes : int ref

(** Install the current [max_depth] / [max_steps] into [Toploop]. Idempotent;
    call once after [Toploop.initialize_toplevel_env]. *)
val configure_toploop : unit -> unit

(** Truncate [s] to [~limit] bytes (default [!max_bytes]), appending an
    elision marker indicating the number of dropped bytes. *)
val truncate_bytes : ?limit:int -> string -> string
