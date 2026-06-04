(** One named host's live connection: SSH child + Unix-socket
    connection to a remote [topup --socket] daemon, plus a per-host
    mutex that serialises requests so the remote Toploop sees them
    one at a time. *)

type t

(** Open an SSH tunnel to [host] and connect to the remote daemon.
    The remote daemon binds [remote_socket] (default
    [~/.topup/sockets/topup.sock]). The local end of the [-L]
    forward is randomized in [/tmp]. Raises [Failure] on SSH spawn
    failure, on connect-retry timeout, or if the initial
    [initialize] handshake does not return within 5 seconds.

    Test-only escape hatch: if the environment variable
    [TOPUP_HOST_SOCKET_<HOST>] is set (with [HOST] uppercased), no
    SSH is spawned and the named local socket path is used directly.
    Intended for cram fixtures pointing at a co-resident
    [topup --socket] daemon. *)
val start : host:string -> ?remote_socket:string -> unit -> t

(** Send one JSON-RPC request and read the matching response.
    Locks the per-host mutex; safe across threads. The function
    overwrites the request's [id] field with a fresh per-host
    sequence number so callers do not need to coordinate ids
    across hosts. The returned message contains the original
    [id] tag chosen by the caller, so wrappers can re-key as
    needed.

    Raises [Failure] if the connection is closed or the remote
    side returns EOF before a response arrives. *)
val send : t -> Yojson.Safe.t -> Yojson.Safe.t

(** Write one JSON-RPC message to the remote without waiting for
    a response. Use for [notifications/*] which by JSON-RPC
    convention carry no [id] and elicit no reply. Locks the
    per-host mutex while writing. Silently no-ops if the
    connection is closed. *)
val notify : t -> Yojson.Safe.t -> unit

(** Tear down the connection and the SSH child. Idempotent. *)
val close : t -> unit

(** Tear down and re-spawn. Same parameters as the original
    {!start}; the underlying [t] is mutated in place so callers
    holding the handle do not need to re-acquire it. *)
val restart : t -> unit

(** The host alias passed to {!start}. *)
val host : t -> string

(** The remote socket path the daemon is listening on. *)
val remote_socket : t -> string

(** ISO-8601 UTC timestamp of the most recent successful {!send},
    or [None] if no message has yet round-tripped. *)
val last_seen : t -> string option

(** [true] when the underlying connection is open and the SSH
    child is alive. Set to [false] by {!close} or by a send-time
    EOF. *)
val is_live : t -> bool
