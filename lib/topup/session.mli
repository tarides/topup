type t

type binding = {
  name : string;
  ty : string;
  location : Error.location option;
  preview : string option;
}

type overflow = Spill.overflow = { path : string; total_bytes : int }

type eval_result = {
  value_repr : string option;
  value_repr_overflow : overflow option;
  ty : string option;
  stdout : string;
  stdout_overflow : overflow option;
  stderr : string;
  stderr_overflow : overflow option;
  warnings : string list;
  error : Error.t option;
}

(** Create a fresh session. If [~log_path] is given, every phrase that
    evaluates without error is appended to that file as raw OCaml, so the
    session can be replayed later by `#use`-ing the file in a new session.
    The file (and any missing parent directory) is created on demand.
    [~checkpoint_dir] enables [checkpoint] / [restore]; the directory is
    created on demand and is NOT wiped (unlike the spill directory). *)
val create : ?log_path:string -> ?checkpoint_dir:string -> unit -> t

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

(** Snapshot the current phrase log under [~label]. The log file is copied
    to the checkpoint directory under that name; a subsequent [restore]
    replays it. Overwrites any existing checkpoint with the same label.
    Returns [Error msg] when phrase logging or checkpointing is disabled,
    or when the label is malformed (must match [\[A-Za-z0-9._-\]+] and
    cannot start with a dot or contain [..]). *)
val checkpoint : t -> label:string -> (unit, string) result

(** Reset the toplevel environment and replay the checkpoint named
    [~label]. The current phrase log is replaced with the checkpoint's
    contents before replay so it stays consistent with the live session.
    The returned [eval_result] reflects the replay; a non-null [error]
    means a phrase failed mid-replay and the session is in an
    intermediate state. Returns [Error msg] if the checkpoint does not
    exist or checkpointing is disabled. Note: [#load]ed libraries are
    not in the log and must be re-loaded after [restore]. *)
val restore : t -> label:string -> (eval_result, string) result

(** Enumerate known checkpoint labels (filename basenames without the
    [.ml] suffix), sorted. Returns the empty list if checkpointing is
    disabled or the directory is empty. *)
val list_checkpoints : t -> string list

(** Promote the current session into a standalone native binary. The
    phrase log is dumped verbatim into a synthesised dune project
    under [~out], built natively, and the resulting executable is
    copied to [out/main.exe]. The wrapper line is
    [let () = ignore (<entry> ())] so [entry] must have type
    [unit -> _]. [libraries] are findlib package names that get listed
    in the synthesised dune file's [(libraries ...)] clause. See
    [Promote.compile_to_binary] for full semantics and error
    conditions. *)
val compile_to_binary :
  t ->
  entry:string ->
  out:string ->
  libraries:string list ->
  (Promote.result, string) result
