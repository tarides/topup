(* Cram-test fixture: bind a Unix socket and accept connections forever
   without ever writing a reply. Used to verify that the MCP server's
   `start_session` handshake bails out via SO_RCVTIMEO instead of
   blocking the dispatcher forever. *)

let () =
  let path = Sys.argv.(1) in
  (try Unix.unlink path with _ -> ());
  let s = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind s (Unix.ADDR_UNIX path);
  Unix.listen s 8;
  print_endline "listening";
  flush stdout;
  while true do
    let c, _ = Unix.accept s in
    (* Hold the connection open without replying. Letting [c] escape
       prevents it from being GC-closed; we never call [Unix.close] on
       it on purpose. *)
    ignore (Sys.opaque_identity c)
  done
