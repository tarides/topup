(** JSON tool descriptors for tools/list. *)
val descriptors : Yojson.Safe.t list

(** Dispatch a [tools/call] by name with raw JSON [args].

    Routing rules, in order:
    - If [args] carries both [host] and [session] string fields that
      both resolve to non-local targets, the call returns an error
      (mutually exclusive).
    - If [args] carries an optional [session] string field that
      resolves to a registered named session, the call is forwarded
      to that subprocess via the {!Session_pool}.
    - If [args] carries an optional [host] string field that resolves
      to a registered remote host, the call is forwarded via the
      {!Host_registry}.
    - Otherwise, the call dispatches to the in-process [session]. *)
val dispatch :
  Topup.Session.t ->
  Host_registry.t ->
  Session_pool.t ->
  string ->
  Yojson.Safe.t ->
  Yojson.Safe.t
