(** In-process registry of named hosts, with on-disk persistence of
    metadata (host name, description, OS, pinned remote socket,
    last-seen timestamp). Live SSH state is never persisted —
    restarted servers come up with no live tunnels and the user (or
    model) must re-issue [start_session] to reconnect. *)

type entry = {
  name : string;
  description : string option;
  os : string option;
  remote_socket : string;
  last_seen : string option;
  host : Remote_host.t option;
}

type t

(** Create the registry, loading [~/.topup/hosts.json] if present.
    The path can be overridden for tests via the [TOPUP_HOSTS_FILE]
    environment variable; if that variable is set to ["off"],
    persistence is disabled entirely. *)
val create : unit -> t

(** Look up an entry by name. Returns [None] if the host has never
    been registered (live or persisted). *)
val lookup : t -> string -> entry option

(** Get the live {!Remote_host.t} for a host, if [start_session] has
    been called this server-lifetime. *)
val live : t -> string -> Remote_host.t option

(** Bring up (or reuse) a host. If a live connection already exists
    for [host], it is returned unchanged (no-op idempotent
    [start_session]). Otherwise a fresh tunnel is opened via
    [Remote_host.start]. Any persisted metadata for the host is
    preserved. *)
val start_session :
  t -> host:string -> ?remote_socket:string -> unit -> Remote_host.t

(** Tear down and re-spawn the host's tunnel. *)
val restart_session : t -> host:string -> Remote_host.t

(** Update the host's metadata. The host must already be registered
    (either live or persisted). *)
val update_host :
  t -> host:string -> ?description:string -> ?os:string -> unit -> unit

(** Iterate over all known entries (live or persisted), sorted by
    name. *)
val iter : t -> (entry -> unit) -> unit

(** Render the registry as the multi-line text that goes into the
    [instructions] field of the [initialize] response. *)
val instructions_text : t -> string

(** Close every live tunnel. Idempotent. *)
val close_all : t -> unit
