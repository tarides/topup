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

let initialize_result : Yojson.Safe.t =
  `Assoc
    [
      ("protocolVersion", `String protocol_version);
      ("capabilities", `Assoc [ ("tools", `Assoc []) ]);
      ( "serverInfo",
        `Assoc
          [ ("name", `String server_name); ("version", `String server_version) ]
      );
    ]

let handle_request session ~id ~meth ~params : Yojson.Safe.t =
  match meth with
  | "initialize" -> json_result id initialize_result
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
          else json_result id (Tools.dispatch session name args)
      | _ -> json_error ~code:(-32602) ~message:"invalid params" id)
  | _ -> json_error ~code:(-32601) ~message:("method not found: " ^ meth) id

let handle_notification session ~meth ~params:_ =
  match meth with
  | "notifications/cancelled" -> Topup.Session.cancel session
  | _ -> ()

let run ~ic ~oc ~session =
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
            Rpc.write_message oc (handle_request session ~id ~meth:m ~params)
        | Some m, None -> handle_notification session ~meth:m ~params
        | None, _ -> ());
        loop ()
    | Some _ -> loop ()
  in
  loop ()
