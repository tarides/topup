(** Stateless file-transfer primitives shared by the
    {!Tools.dispatch_local} blob-tool branches and by
    {!Channel.create}'s [~on_request] callback for the muxed back
    channel. Both sides of the SSH tunnel call the same code; the
    only difference is which filesystem the call lands on. *)

(** [dispatch name args] handles [_send_blob] and [_recv_blob] using
    the current process's filesystem; returns a JSON-RPC result
    payload. Returns an error result for any other tool name (the
    intent is to scope what the back channel exposes — adding tools
    here is a deliberate widening of trust). *)
val dispatch : string -> Yojson.Safe.t -> Yojson.Safe.t
