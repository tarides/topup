(** JSON tool descriptors for tools/list. *)
val descriptors : Yojson.Safe.t list

(** Dispatch a [tools/call] by name with raw JSON [args].

    If [args] carries an optional [host] string field that does not
    resolve to the local session (i.e. it is not [null], [""], or
    ["local"]), the call is forwarded to the named host's
    {!Remote_host} via the registry. The remote's tool response is
    returned verbatim. Hosts that have not been brought up via
    [start_session] yield a structured error. *)
val dispatch :
  Topup.Session.t ->
  Host_registry.t ->
  string ->
  Yojson.Safe.t ->
  Yojson.Safe.t
