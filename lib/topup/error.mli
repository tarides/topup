type phase = Typecheck | Runtime

type location = {
  file : string;
  line : int;
  col_start : int;
  col_end : int;
}

type t = {
  phase : phase;
  location : location option;
  message : string;
  related : string list;
}

(** Translate an exception raised during evaluation into a structured error.
    Uses [Location.error_of_exn] for typecheck/parse exceptions registered
    with [register_error_of_exn]; falls back to [Printexc.to_string] for
    runtime exceptions. *)
val of_exn : exn -> t

(** Build a runtime-phase error from an unhandled user exception. *)
val of_runtime_exn : exn -> t

(** Translate a compiler [Location.t] to a serialisable [location]. Returns
    [None] for ghost locations. *)
val location_of_loc : Location.t -> location option
