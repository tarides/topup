(** Bidirectional JSON-RPC channel over a paired [in_channel] /
    [out_channel]. Each end can send requests AND receive requests on
    the same socket; a single reader thread demuxes incoming frames
    into responses (which resolve waiting senders) and inbound
    requests (which are dispatched to short-lived worker threads).

    Wire compatibility: frames are newline-delimited JSON via
    {!Rpc.read_message} / {!Rpc.write_message}, identical to the
    pre-muxer transport. *)

type t

(** [create ~ic ~oc ~on_request] takes ownership of the channel ends
    and spawns a reader thread. Each inbound request is dispatched
    on a worker thread that calls [on_request] and writes the reply
    back; notifications also call [on_request] but the result is
    discarded. *)
val create :
  ic:in_channel ->
  oc:out_channel ->
  on_request:(Yojson.Safe.t -> Yojson.Safe.t) ->
  t

(** [request t req] writes [req] (allocating and setting the [id]
    field to a fresh monotonic integer) and blocks until the matching
    response arrives. Raises [Failure] if the channel closes before
    the response or the write fails. *)
val request : t -> Yojson.Safe.t -> Yojson.Safe.t

(** [notify t msg] writes a JSON-RPC notification (no [id], no
    response expected). Silently drops write errors — callers that
    care about delivery should use {!request}. *)
val notify : t -> Yojson.Safe.t -> unit

(** [close t] closes the underlying channels and aborts every
    in-flight {!request}. Idempotent. *)
val close : t -> unit

(** [is_closed t] reports whether [close] was called or the reader
    has observed EOF. *)
val is_closed : t -> bool

(** [wait_closed t] blocks the calling thread until the channel is
    closed (peer EOF, write failure, or explicit {!close}). *)
val wait_closed : t -> unit
