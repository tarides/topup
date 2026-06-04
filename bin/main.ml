let resolve_log_path () =
  match Sys.getenv_opt "TOPUP_LOG" with
  | Some "off" | Some "" -> None
  | Some path -> Some path
  | None -> (
      match Sys.getenv_opt "HOME" with
      | Some home -> Some (Filename.concat home ".topup/history.ml")
      | None -> None)

let resolve_checkpoint_dir () =
  match Sys.getenv_opt "TOPUP_CHECKPOINT_DIR" with
  | Some "off" | Some "" -> None
  | Some path -> Some path
  | None -> (
      match Sys.getenv_opt "HOME" with
      | Some home -> Some (Filename.concat home ".topup/checkpoints")
      | None -> None)

let make_session () =
  let log_path = resolve_log_path () in
  let checkpoint_dir = resolve_checkpoint_dir () in
  Topup.Session.create ?log_path ?checkpoint_dir ()

let make_registry () = Mcp.Host_registry.create ()

let die_on_failure f =
  try f ()
  with Failure msg ->
    prerr_endline msg;
    exit 1

let usage =
  "usage: topup-mcp [--socket <path> | --proxy <path> | --remote <host> \
   [--remote-socket <path>]]"

let run_remote_via_registry ~host ?remote_socket () =
  let session = make_session () in
  let registry = make_registry () in
  let _ : Mcp.Remote_host.t =
    Mcp.Host_registry.start_session registry ~host ?remote_socket ()
  in
  at_exit (fun () -> Mcp.Host_registry.close_all registry);
  Mcp.Server.run ~ic:stdin ~oc:stdout ~session ~registry ~default_host:host ()

let () =
  match Array.to_list Sys.argv with
  | [ _ ] ->
      let session = make_session () in
      let registry = make_registry () in
      at_exit (fun () -> Mcp.Host_registry.close_all registry);
      Mcp.Server.run ~ic:stdin ~oc:stdout ~session ~registry ()
  | [ _; "--socket"; path ] ->
      die_on_failure (fun () ->
          let session = make_session () in
          let registry = make_registry () in
          at_exit (fun () -> Mcp.Host_registry.close_all registry);
          Mcp.Server.serve_unix ~path ~session ~registry ())
  | [ _; "--proxy"; path ] ->
      die_on_failure (fun () -> Mcp.Proxy.run_proxy ~socket_path:path ())
  | [ _; "--remote"; host ] ->
      die_on_failure (fun () -> run_remote_via_registry ~host ())
  | [ _; "--remote"; host; "--remote-socket"; remote_sock ] ->
      die_on_failure (fun () ->
          run_remote_via_registry ~host ~remote_socket:remote_sock ())
  | _ ->
      prerr_endline usage;
      exit 2
