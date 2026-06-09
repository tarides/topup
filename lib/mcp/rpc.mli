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

(** Write one JSON-RPC message to [oc] and flush. *)
val write_message : out_channel -> message -> unit
