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

(** Create a fresh session. If [~log_path] is given, every phrase that
    evaluates without error is appended to that file as raw OCaml, so the
    session can be replayed later by `#use`-ing the file in a new session.
    The file (and any missing parent directory) is created on demand. *)
val create : ?log_path:string -> unit -> t

(** Evaluate one or more OCaml phrases. If [timeout] is given, evaluation is
    interrupted after that many seconds and a cancellation error is returned. *)
val eval : ?timeout:float -> t -> string -> eval_result

(** Enumerate current bindings, optionally name-prefix filtered. By default
    only user-defined bindings (those originating from an [<eval>] phrase)
    are returned; pass [~all:true] to also include stdlib / predef and
    other library bindings. *)
val env : ?filter:string -> ?all:bool -> t -> binding list

(** Look up one binding by name. *)
val lookup : t -> string -> binding option

(** Discard the toplevel environment and start fresh. *)
val reset : t -> unit

(** Request interruption of the currently-running phrase. *)
val cancel : t -> unit
