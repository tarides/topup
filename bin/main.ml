let resolve_log_path () =
  match Sys.getenv_opt "TOPUP_LOG" with
  | Some "off" | Some "" -> None
  | Some path -> Some path
  | None -> (
      match Sys.getenv_opt "HOME" with
      | Some home -> Some (Filename.concat home ".topup/history.ml")
      | None -> None)

let server () =
  let log_path = resolve_log_path () in
  Topup.Session.create ?log_path ()

let die_on_failure f =
  try f ()
  with Failure msg ->
    prerr_endline msg;
    exit 1

let usage =
  "usage: topup-mcp [--socket <path> | --proxy <path> | --remote <host> \
   [--remote-socket <path>]]"

let () =
  match Array.to_list Sys.argv with
  | [ _ ] ->
      let session = server () in
      Mcp.Server.run ~ic:stdin ~oc:stdout ~session
  | [ _; "--socket"; path ] ->
      die_on_failure (fun () ->
          let session = server () in
          Mcp.Server.serve_unix ~path ~session)
  | [ _; "--proxy"; path ] ->
      die_on_failure (fun () -> Mcp.Proxy.run_proxy ~socket_path:path ())
  | [ _; "--remote"; host ] ->
      die_on_failure (fun () -> Mcp.Proxy.run_remote ~host ())
  | [ _; "--remote"; host; "--remote-socket"; remote_sock ] ->
      die_on_failure (fun () ->
          Mcp.Proxy.run_remote ~host ~remote_socket:remote_sock ())
  | _ ->
      prerr_endline usage;
      exit 2
