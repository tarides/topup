(** Functions callable from inside a user phrase to reach back across
    the local↔remote boundary. The in-process and named-local-session
    cases default to direct file I/O (the chatbot's filesystem is
    accessible directly). The routed-to-remote case is wired by
    {!install_hook} to send a JSON-RPC request back to the local
    server. *)

(** Read the contents of a file on the orchestrator's filesystem.
    Raises [Failure] on I/O error or when the file exceeds
    [TOPUP_XFER_MAX_BYTES] (default 16 MiB). *)
val read_back : string -> bytes

(** Atomically write bytes to a file on the orchestrator's filesystem.
    Raises [Failure] on I/O error or when the payload exceeds
    [TOPUP_XFER_MAX_BYTES]. *)
val write_back : string -> bytes -> unit

type io_hook = {
  read : string -> bytes;
  write : string -> bytes -> unit;
}

(** Default hook: direct file I/O on the current process's filesystem.
    Installed at module init. *)
val direct_hook : io_hook

(** Replace the active hook. The remote daemon installs a muxed hook
    (back-channel JSON-RPC) when it accepts a connection; the default
    [direct_hook] is restored when the connection closes. *)
val install_hook : io_hook -> unit
