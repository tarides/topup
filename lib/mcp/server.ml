let protocol_version = "2024-11-05"
let server_name = "topup"
let server_version = "0.1.0"

let json_result id result : Yojson.Safe.t =
  `Assoc
    [
      ("jsonrpc", `String "2.0"); ("id", id); ("result", result);
    ]

let json_error ?(code = -32603) ?(message = "Internal error") id : Yojson.Safe.t =
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("id", id);
      ( "error",
        `Assoc [ ("code", `Int code); ("message", `String message) ] );
    ]

let initialize_result registry : Yojson.Safe.t =
  `Assoc
    [
      ("protocolVersion", `String protocol_version);
      ("capabilities", `Assoc [ ("tools", `Assoc []) ]);
      ( "serverInfo",
        `Assoc
          [ ("name", `String server_name); ("version", `String server_version) ]
      );
      ("instructions", `String (Host_registry.instructions_text registry));
    ]

let inject_default_host ~default_host (args : Yojson.Safe.t) : Yojson.Safe.t =
  match default_host with
  | None -> args
  | Some host -> (
      match args with
      | `Assoc fields ->
          let has_host = List.exists (fun (k, _) -> k = "host") fields in
          if has_host then args
          else `Assoc (("host", `String host) :: fields)
      | _ -> `Assoc [ ("host", `String host) ])

let handle_request ~session ~registry ~default_host ~id ~meth ~params :
    Yojson.Safe.t =
  match meth with
  | "initialize" -> json_result id (initialize_result registry)
  | "tools/list" ->
      json_result id (`Assoc [ ("tools", `List Tools.descriptors) ])
  | "tools/call" -> (
      match params with
      | `Assoc fields ->
          let name =
            match List.assoc_opt "name" fields with
            | Some (`String s) -> s
            | _ -> ""
          in
          let args =
            match List.assoc_opt "arguments" fields with
            | Some j -> j
            | None -> `Assoc []
          in
          if name = "" then
            json_error ~code:(-32602) ~message:"missing tool name" id
          else
            let args =
              match name with
              | "start_session" | "restart_session" | "update_host" -> args
              | _ -> inject_default_host ~default_host args
            in
            json_result id (Tools.dispatch session registry name args)
      | _ -> json_error ~code:(-32602) ~message:"invalid params" id)
  | _ -> json_error ~code:(-32601) ~message:("method not found: " ^ meth) id

let handle_notification ~session ~registry ~default_host ~meth ~params =
  match meth with
  | "notifications/cancelled" ->
      let host =
        match params with
        | `Assoc fields -> (
            match List.assoc_opt "host" fields with
            | Some (`String "") | Some (`String "local") | None ->
                default_host
            | Some (`String h) -> Some h
            | _ -> default_host)
        | _ -> default_host
      in
      (match host with
       | None -> Topup.Session.cancel session
       | Some host -> (
           match Host_registry.live registry host with
           | None -> ()
           | Some rh ->
               let msg : Yojson.Safe.t =
                 `Assoc
                   [
                     ("jsonrpc", `String "2.0");
                     ("method", `String "notifications/cancelled");
                     ("params", `Assoc []);
                   ]
               in
               Remote_host.notify rh msg))
  | _ -> ()

let run ~ic ~oc ~session ~registry ?default_host () =
  let rec loop () =
    match Rpc.read_message ic with
    | None -> ()
    | Some (`Assoc fields) ->
        let meth_opt =
          match List.assoc_opt "method" fields with
          | Some (`String s) -> Some s
          | _ -> None
        in
        let params =
          match List.assoc_opt "params" fields with
          | Some j -> j
          | None -> `Null
        in
        let id_opt = List.assoc_opt "id" fields in
        (match (meth_opt, id_opt) with
        | Some m, Some id ->
            Rpc.write_message oc
              (handle_request ~session ~registry ~default_host ~id ~meth:m
                 ~params)
        | Some m, None ->
            handle_notification ~session ~registry ~default_host ~meth:m
              ~params
        | None, _ -> ());
        loop ()
    | Some _ -> loop ()
  in
  loop ()

let prepare_socket_path path =
  match Unix.stat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | exception Unix.Unix_error (err, _, _) ->
      failwith
        (Printf.sprintf "topup-mcp: cannot stat %s: %s" path
           (Unix.error_message err))
  | _ ->
      let probe = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      let live =
        match Unix.connect probe (Unix.ADDR_UNIX path) with
        | () -> true
        | exception Unix.Unix_error (Unix.ECONNREFUSED, _, _) -> false
        | exception Unix.Unix_error (Unix.ENOENT, _, _) -> false
        | exception Unix.Unix_error _ -> false
      in
      (try Unix.close probe with _ -> ());
      if live then
        failwith
          (Printf.sprintf
             "topup-mcp: socket %s is in use by another process" path);
      (try Unix.unlink path
       with Unix.Unix_error (Unix.ENOENT, _, _) -> ())

let serve_unix ~path ~session ~registry ?default_host () =
  prepare_socket_path path;
  let server = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind server (Unix.ADDR_UNIX path);
  Unix.listen server 1;
  at_exit (fun () ->
      try Unix.unlink path with _ -> ());
  let exit_on signal =
    try Sys.set_signal signal (Sys.Signal_handle (fun _ -> exit 0))
    with Invalid_argument _ -> ()
  in
  exit_on Sys.sigterm;
  exit_on Sys.sighup;
  (try Sys.set_signal Sys.sigpipe Sys.Signal_ignore
   with Invalid_argument _ -> ());
  while true do
    let client, _ = Unix.accept server in
    let ic = Unix.in_channel_of_descr client in
    let oc = Unix.out_channel_of_descr client in
    (try run ~ic ~oc ~session ~registry ?default_host () with _ -> ());
    (try close_in ic with _ -> ());
    (try close_out oc with _ -> ())
  done
