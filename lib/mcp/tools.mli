(** JSON tool descriptors for tools/list. *)
val descriptors : Yojson.Safe.t list

(** Dispatch a [tools/call] by name with raw JSON [args]. *)
val dispatch : Topup.Session.t -> string -> Yojson.Safe.t -> Yojson.Safe.t
