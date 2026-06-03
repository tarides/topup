type message = Yojson.Safe.t

(** Read one JSON-RPC message from [ic]. Returns [None] on EOF. *)
val read_message : in_channel -> message option

(** Write one JSON-RPC message to [oc] and flush. *)
val write_message : out_channel -> message -> unit
