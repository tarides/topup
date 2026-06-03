let pipe_pair () =
  let r, w = Unix.pipe ~cloexec:true () in
  (Unix.in_channel_of_descr r, Unix.out_channel_of_descr w)

let test_rpc_roundtrip () =
  let ic, oc = pipe_pair () in
  let msg : Yojson.Safe.t =
    `Assoc
      [
        ("jsonrpc", `String "2.0");
        ("id", `Int 7);
        ("method", `String "ping");
      ]
  in
  Mcp.Rpc.write_message oc msg;
  match Mcp.Rpc.read_message ic with
  | Some got when got = msg -> ()
  | Some got ->
      Printf.printf "FAIL rpc: got %s\n" (Yojson.Safe.to_string got);
      exit 1
  | None ->
      print_endline "FAIL rpc: EOF";
      exit 1

let fail msg =
  print_endline ("FAIL " ^ msg);
  exit 1

let with_server f =
  let cs_ic, cs_oc = pipe_pair () in
  let sc_ic, sc_oc = pipe_pair () in
  let session = Topup.Session.create () in
  let t =
    Thread.create
      (fun () -> Mcp.Server.run ~ic:cs_ic ~oc:sc_oc ~session)
      ()
  in
  let result = f sc_ic cs_oc in
  close_out cs_oc;
  Thread.join t;
  result

let request id meth ?(params : Yojson.Safe.t option) () : Yojson.Safe.t =
  let base =
    [
      ("jsonrpc", `String "2.0");
      ("id", `Int id);
      ("method", `String meth);
    ]
  in
  let fields =
    match params with Some p -> base @ [ ("params", p) ] | None -> base
  in
  `Assoc fields

let read_response_id ic =
  match Mcp.Rpc.read_message ic with
  | Some j -> j
  | None -> fail "no response from server"

let get_in (j : Yojson.Safe.t) keys =
  let rec walk j = function
    | [] -> j
    | k :: rest ->
        (match j with
         | `Assoc fields ->
             (match List.assoc_opt k fields with
              | Some v -> walk v rest
              | None -> fail ("missing field: " ^ k))
         | _ -> fail "expected object")
  in
  walk j keys

let test_initialize_list_call () =
  with_server (fun ic oc ->
      Mcp.Rpc.write_message oc (request 1 "initialize" ());
      let r = read_response_id ic in
      (match get_in r [ "result"; "serverInfo"; "name" ] with
       | `String "topup" -> ()
       | _ -> fail "initialize serverInfo.name");
      Mcp.Rpc.write_message oc (request 2 "tools/list" ());
      let r = read_response_id ic in
      (match get_in r [ "result"; "tools" ] with
       | `List tools when List.length tools = 5 -> ()
       | `List tools ->
           Printf.printf "FAIL tools/list: got %d tools\n" (List.length tools);
           exit 1
       | _ -> fail "tools/list shape");
      let call_eval source =
        let params =
          `Assoc
            [
              ("name", `String "eval");
              ("arguments", `Assoc [ ("source", `String source) ]);
            ]
        in
        Mcp.Rpc.write_message oc (request 3 "tools/call" ~params ());
        read_response_id ic
      in
      let r1 = call_eval "let z = 21 * 2;;" in
      let text =
        match get_in r1 [ "result"; "content" ] with
        | `List [ `Assoc fs ] -> (
            match List.assoc_opt "text" fs with
            | Some (`String s) -> s
            | _ -> fail "no text in content")
        | _ -> fail "content shape"
      in
      let payload = Yojson.Safe.from_string text in
      (match get_in payload [ "value_repr" ] with
       | `String "42" -> ()
       | _ -> fail "eval value_repr != 42");
      ())

let () =
  test_rpc_roundtrip ();
  test_initialize_list_call ();
  let _ : Yojson.Safe.t list = Mcp.Tools.descriptors in
  print_endline "test_mcp: ok"
