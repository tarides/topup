type message = Yojson.Safe.t

(** Raised by {!read_message} when a single frame exceeds the byte cap
    (carries the cap). *)
exception Message_too_large of int

(** Per-frame byte cap: [TOPUP_MAX_MESSAGE_BYTES], default 64 MiB. *)
val max_message_bytes : unit -> int

(** Read one JSON-RPC message from [ic]. Returns [None] on EOF. Raises
    {!Message_too_large} if the frame exceeds {!max_message_bytes}
    (instead of allocating without bound), and the usual
    [Yojson.Json_error] on malformed JSON. *)
val read_message : in_channel -> message option

(** Raised by {!read_message_deadline} when the wall-clock deadline
    passes before a full frame has been read. *)
exception Timeout

(** Read one JSON-RPC message directly from [fd] under an absolute
    wall-clock [deadline] ([Unix.gettimeofday] seconds), using
    [Unix.select] for readiness. Portable alternative to relying on
    [SO_RCVTIMEO], which does not interrupt a blocking read on all
    platforms. Consumes exactly one newline-terminated frame (nothing
    past the ['\n']), so a buffered [in_channel] over the same [fd] may
    be used afterwards. Returns [None] on EOF; raises {!Timeout} on
    deadline, {!Message_too_large} past the cap, and [Yojson.Json_error]
    on malformed JSON. *)
val read_message_deadline :
  Unix.file_descr -> deadline:float -> message option

(** Write one JSON-RPC message to [oc] and flush. *)
val write_message : out_channel -> message -> unit
