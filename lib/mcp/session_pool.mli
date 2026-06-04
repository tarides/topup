(** In-process registry of named local sessions. Each entry is a
    [topup --socket] subprocess multiplexed by name, with optional
    pre-warming and an optional pool of replica siblings spawned at
    creation time. Persists metadata (name, prewarm path, pool size,
    last-seen timestamp) under [~/.topup/sessions.json] (or the path
    in [TOPUP_SESSIONS_FILE]; [=off] disables persistence). Live
    subprocess state is never persisted — restarted servers come up
    with no live sessions, and the user (or model) must re-issue
    [start_session] to bring them back up. *)

type entry = {
  name : string;
  prewarm : string option;
  pool : int;
  last_seen : string option;
  session : Local_session.t option;
}

type t

(** Create the registry, loading [~/.topup/sessions.json] if present.
    Override path via [TOPUP_SESSIONS_FILE]; set to ["off"] to
    disable persistence entirely. *)
val create : unit -> t

(** Look up an entry by name. Returns [None] if the session has
    never been registered (live or persisted). *)
val lookup : t -> string -> entry option

(** Get the live {!Local_session.t} for a name, if [start_session]
    has been called this server-lifetime. *)
val live : t -> string -> Local_session.t option

(** Bring up (or reuse) a named session. If a live subprocess
    already exists for [name], it is returned unchanged. Otherwise
    a fresh subprocess is spawned via [Local_session.start] with the
    given [prewarm].

    When [pool] is greater than 1, [pool - 1] sibling sessions named
    [name.1] … [name.(pool-1)] are also brought up, all sharing the
    same [prewarm]. Sibling spawn failures do not roll back the
    primary; they surface as [Failure] from the first failing
    sibling, leaving earlier siblings live. *)
val start_session :
  t ->
  name:string ->
  ?prewarm:string ->
  ?pool:int ->
  unit ->
  Local_session.t

(** Tear down and re-spawn the session's subprocess. *)
val restart_session : t -> name:string -> Local_session.t

(** Update the session's metadata (prewarm path, pool size) in
    persistent storage. Does not affect any running subprocess —
    a restart is needed for changes to take effect on the live
    session. *)
val update_session :
  t ->
  name:string ->
  ?prewarm:string ->
  ?pool:int ->
  unit ->
  unit

(** Iterate over all known entries (live or persisted), sorted by
    name. *)
val iter : t -> (entry -> unit) -> unit

(** Render the registry as the multi-line text appended to the
    [instructions] field of the [initialize] response. Empty string
    when no sessions are registered. *)
val instructions_text : t -> string

(** Close every live subprocess. Idempotent. *)
val close_all : t -> unit
