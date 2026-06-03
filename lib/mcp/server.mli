(** Run the MCP server loop until [ic] returns EOF. *)
val run : ic:in_channel -> oc:out_channel -> session:Topup.Session.t -> unit
