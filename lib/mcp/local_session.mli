(** One named local session's live connection: child [topup --socket]
    process + Unix-socket connection, plus a per-session mutex that
    serialises requests so the in-subprocess Toploop sees them one at
    a time. Same shape as {!Remote_host} but without the SSH spawn —
    the subprocess is a fork+exec of the current [topup] binary. *)

type t

(** Fork+exec a [topup --socket <path>] subprocess and connect to it.
    The subprocess binds [local_socket] (default
    [/tmp/topup-session-<name>-<rand>.sock]) and runs in the current
    user's environment. If [prewarm] is given, [#use <prewarm>;;] is
    evaluated in the subprocess before {!start} returns; a non-null
    error from that eval aborts the spawn and the subprocess is killed.

    Test-only escape hatch: if the environment variable
    [TOPUP_SESSION_SOCKET_<NAME>] is set (with [NAME] uppercased), no
    subprocess is spawned and the named socket path is used directly.
    Intended for cram fixtures pointing at a co-resident
    [topup --socket] daemon. *)
val start :
  name:string -> ?local_socket:string -> ?prewarm:string -> unit -> t

(** Send one JSON-RPC request and read the matching response. Locks
    the per-session mutex; safe across threads. Overwrites the
    request's [id] field with a fresh per-session sequence number. *)
val send : t -> Yojson.Safe.t -> Yojson.Safe.t

(** Write one JSON-RPC message without waiting for a response.
    Silently no-ops if the connection is closed. *)
val notify : t -> Yojson.Safe.t -> unit

(** Tear down the connection and the subprocess. Idempotent. *)
val close : t -> unit

(** Tear down and re-spawn the subprocess. Same parameters as the
    original {!start}; the underlying [t] is mutated in place. The
    [prewarm] phrase, if any, is replayed against the new
    subprocess. *)
val restart : t -> unit

(** The session name passed to {!start}. *)
val name : t -> string

(** The local socket path the subprocess is listening on. *)
val local_socket : t -> string

(** The prewarm path, if any. *)
val prewarm : t -> string option

(** ISO-8601 UTC timestamp of the most recent successful {!send},
    or [None] if no message has yet round-tripped. *)
val last_seen : t -> string option

(** [true] when the underlying connection is open and the subprocess
    is alive. *)
val is_live : t -> bool
