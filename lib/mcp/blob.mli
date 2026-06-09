(** Stateless file-transfer primitives shared by the
    {!Tools.dispatch_local} blob-tool branches and by
    {!Channel.create}'s [~on_request] callback for the muxed back
    channel. Both sides of the SSH tunnel call the same code; the
    only difference is which filesystem the call lands on. *)

(** [dispatch ?confine_root name args] handles [_send_blob] and
    [_recv_blob] using the current process's filesystem; returns a
    JSON-RPC result payload. Returns an error result for any other tool
    name (the intent is to scope what the back channel exposes — adding
    tools here is a deliberate widening of trust).

    When [confine_root] is given, the requested path is reinterpreted
    *under* that root and any [..]/symlink escape is rejected. The
    back-channel reader ({!Remote_host}) passes it so a remote peer
    cannot reach arbitrary local files; the user's own
    [push_file]/[pull_file] path leaves it unset (intentionally
    unconfined — the path is user-chosen and local). *)
val dispatch :
  ?confine_root:string -> string -> Yojson.Safe.t -> Yojson.Safe.t

(** Confinement root for back-channel blob operations:
    [$TOPUP_BACKCHANNEL_ROOT] (default [$HOME/.topup/back]); returns
    [None] only when the variable is set to ["off"] (unconfined). *)
val backchannel_confine_root : unit -> string option
