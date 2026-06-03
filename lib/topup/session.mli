type t

type binding = {
  name : string;
  ty : string;
  location : Error.location option;
  preview : string option;
}

type eval_result = {
  value_repr : string option;
  ty : string option;
  stdout : string;
  stderr : string;
  warnings : string list;
  error : Error.t option;
}

val create : unit -> t

(** Evaluate one or more OCaml phrases. If [timeout] is given, evaluation is
    interrupted after that many seconds and a cancellation error is returned. *)
val eval : ?timeout:float -> t -> string -> eval_result

(** Enumerate current bindings, optionally name-prefix filtered. *)
val env : ?filter:string -> t -> binding list

(** Look up one binding by name. *)
val lookup : t -> string -> binding option

(** Discard the toplevel environment and start fresh. *)
val reset : t -> unit

(** Request interruption of the currently-running phrase. *)
val cancel : t -> unit
