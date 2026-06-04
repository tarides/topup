(** Bidirectional stdio↔Unix-socket bridge. Connects to [socket_path]
    with a retry loop (default 10 s, retries [ENOENT] / [ECONNREFUSED]
    while the peer is coming up), then pipes [stdin] to the socket and
    the socket to [stdout] via two threads until either side closes.
    Returns when the socket→stdout direction reaches EOF; the
    stdin→socket thread is left to the runtime to tear down at process
    exit. Raises [Failure] if the connect retry deadline is hit or a
    non-retryable error fires. *)
val run_proxy :
  socket_path:string -> ?connect_timeout:float -> unit -> unit

(** Spawn an SSH child that forwards a Unix socket from the remote
    host and runs [topup --socket <remote_socket>] there, then drives
    {!run_proxy} against the local end of the forward. The local
    socket path is randomized in [/tmp]; the remote socket defaults
    to [/tmp/topup-<random>.sock] and may be pinned with
    [?remote_socket] so reconnections land on the same session.
    Installs [at_exit] to kill the SSH child and unlink the local
    socket; installs [SIGTERM] / [SIGINT] handlers that call [exit 0]
    so the cleanup runs under shell termination. Returns when the
    proxy's socket→stdout direction reaches EOF. *)
val run_remote : host:string -> ?remote_socket:string -> unit -> unit
