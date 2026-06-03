let resolve_log_path () =
  match Sys.getenv_opt "TOPUP_LOG" with
  | Some "off" | Some "" -> None
  | Some path -> Some path
  | None -> (
      match Sys.getenv_opt "HOME" with
      | Some home -> Some (Filename.concat home ".topup/history.ml")
      | None -> None)

let () =
  let log_path = resolve_log_path () in
  let session = Topup.Session.create ?log_path () in
  Mcp.Server.run ~ic:stdin ~oc:stdout ~session
