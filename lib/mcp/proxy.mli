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

(** Connect to a Unix socket at [path], retrying [ENOENT] / [ECONNREFUSED]
    until [timeout] seconds elapse. Returns the connected file
    descriptor. Raises [Failure] on timeout or non-retryable error. *)
val connect_with_retry : path:string -> timeout:float -> Unix.file_descr

type ssh_handle = {
  ssh_pid : int;
  local_sock : string;
  remote_sock : string;
}

(** Spawn an SSH child that forwards a Unix socket from [host]'s
    [remote_sock] back to a randomly-chosen local Unix socket, and runs
    [topup --socket <remote_sock>] on the remote side. [remote_socket]
    pins the remote path (default is randomized in [/tmp]). Does NOT
    install any signal handlers or [at_exit] hooks — the caller owns
    cleanup via {!kill_ssh}. *)
val spawn_ssh : host:string -> ?remote_socket:string -> unit -> ssh_handle

(** Kill the SSH child and unlink the local socket. Idempotent. *)
val kill_ssh : ssh_handle -> unit

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
