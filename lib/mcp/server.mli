(** Run the MCP server loop until [ic] returns EOF. *)
val run : ic:in_channel -> oc:out_channel -> session:Topup.Session.t -> unit

(** Bind a Unix socket at [path] and serve the MCP protocol over
    accepted connections, one client at a time. State persists in
    [session] across connection boundaries. If [path] already exists
    and a live peer answers on it, [Failure] is raised; otherwise the
    stale socket file is unlinked before binding. The socket file is
    unlinked on normal exit (via [at_exit]); a [SIGTERM] handler is
    installed that triggers normal exit so the cleanup runs. Returns
    only when the process exits. *)
val serve_unix : path:string -> session:Topup.Session.t -> unit
