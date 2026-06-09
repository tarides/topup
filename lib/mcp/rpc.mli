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

(** {2 Envelope constructors}

    Single home for the [("jsonrpc", "2.0")] boilerplate. *)

(** A request: [{ jsonrpc; id; method; params? }]. *)
val request : ?params:message -> id:message -> string -> message

(** A success response: [{ jsonrpc; id; result }]. *)
val response : id:message -> message -> message

(** An error response: [{ jsonrpc; id; error = { code; message } }].
    [code] defaults to [-32603] (internal error). *)
val error : ?code:int -> ?message:string -> message -> message
