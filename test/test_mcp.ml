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
  let registry = Mcp.Host_registry.create () in
  let t =
    Thread.create
      (fun () -> Mcp.Server.run ~ic:cs_ic ~oc:sc_oc ~session ~registry ())
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
       | `List tools when List.length tools = 10 -> ()
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
      List.iter
        (fun field ->
          match get_in payload [ field ] with
          | `Null -> ()
          | _ -> fail (field ^ " unexpectedly set for small eval"))
        [ "value_repr_overflow"; "stdout_overflow"; "stderr_overflow" ];
      let r2 =
        let params =
          `Assoc
            [
              ("name", `String "eval");
              ( "arguments",
                `Assoc
                  [
                    ( "source",
                      `String
                        "print_string (String.make 20000 'y');;" );
                  ] );
            ]
        in
        Mcp.Rpc.write_message oc (request 4 "tools/call" ~params ());
        read_response_id ic
      in
      let text2 =
        match get_in r2 [ "result"; "content" ] with
        | `List [ `Assoc fs ] -> (
            match List.assoc_opt "text" fs with
            | Some (`String s) -> s
            | _ -> fail "no text in content")
        | _ -> fail "content shape"
      in
      let payload2 = Yojson.Safe.from_string text2 in
      (match get_in payload2 [ "stdout_overflow"; "path" ] with
       | `String p when Sys.file_exists p -> ()
       | _ -> fail "stdout_overflow.path missing or not a file");
      (match get_in payload2 [ "stdout_overflow"; "total_bytes" ] with
       | `Int n when n >= 20000 -> ()
       | _ -> fail "stdout_overflow.total_bytes wrong");
      let call_load path =
        let params =
          `Assoc
            [
              ("name", `String "load");
              ("arguments", `Assoc [ ("path", `String path) ]);
            ]
        in
        Mcp.Rpc.write_message oc (request 5 "tools/call" ~params ());
        read_response_id ic
      in
      let text_of resp =
        match get_in resp [ "result"; "content" ] with
        | `List [ `Assoc fs ] -> (
            match List.assoc_opt "text" fs with
            | Some (`String s) -> s
            | _ -> fail "no text in content")
        | _ -> fail "content shape"
      in
      let fixture_cma =
        Filename.concat (Sys.getcwd ())
          "fixtures/topup_load_fixture/topup_load_fixture.cma"
      in
      if not (Sys.file_exists fixture_cma) then
        fail ("fixture cma missing: " ^ fixture_cma);
      let r_load = call_load fixture_cma in
      let payload_load = Yojson.Safe.from_string (text_of r_load) in
      (match get_in payload_load [ "error" ] with
       | `Null -> ()
       | _ -> fail "load fixture: unexpected error");
      let r_use = call_eval "Topup_load_fixture.answer;;" in
      let payload_use = Yojson.Safe.from_string (text_of r_use) in
      (match get_in payload_use [ "value_repr" ] with
       | `String "42" -> ()
       | _ -> fail "loaded fixture's answer != 42");
      let r_bad = call_load "/definitely/not/a/real/path.cma" in
      let payload_bad = Yojson.Safe.from_string (text_of r_bad) in
      (match payload_bad with
       | `Assoc _ -> ()
       | _ -> fail "load bad path: malformed payload");
      ())

let contains haystack needle =
  let nh = String.length haystack in
  let nn = String.length needle in
  if nn = 0 then true
  else
    let last = nh - nn in
    let rec loop i =
      if i > last then false
      else if String.sub haystack i nn = needle then true
      else loop (i + 1)
    in
    loop 0

let test_initialize_has_instructions () =
  with_server (fun ic oc ->
      Mcp.Rpc.write_message oc (request 1 "initialize" ());
      let r = read_response_id ic in
      match get_in r [ "result"; "instructions" ] with
      | `String s when String.length s > 0 && contains s "local" -> ()
      | _ -> fail "initialize result missing instructions or 'local' marker")

let test_unknown_host_errors () =
  with_server (fun ic oc ->
      let params =
        `Assoc
          [
            ("name", `String "eval");
            ( "arguments",
              `Assoc
                [
                  ("host", `String "no-such-host");
                  ("source", `String "1+1;;");
                ] );
          ]
      in
      Mcp.Rpc.write_message oc (request 9 "tools/call" ~params ());
      let r = read_response_id ic in
      match get_in r [ "result"; "isError" ] with
      | `Bool true -> ()
      | _ -> fail "expected isError true for unknown host")

let test_host_local_aliases () =
  with_server (fun ic oc ->
      let bind =
        `Assoc
          [
            ("name", `String "eval");
            ( "arguments",
              `Assoc
                [
                  ("host", `String "local");
                  ("source", `String "let lh = 7 * 7;;");
                ] );
          ]
      in
      Mcp.Rpc.write_message oc (request 10 "tools/call" ~params:bind ());
      let _ = read_response_id ic in
      let read_back =
        `Assoc
          [ ("name", `String "eval");
            ("arguments", `Assoc [ ("source", `String "lh;;") ]) ]
      in
      Mcp.Rpc.write_message oc (request 11 "tools/call" ~params:read_back ());
      let r = read_response_id ic in
      let text =
        match get_in r [ "result"; "content" ] with
        | `List [ `Assoc fs ] -> (
            match List.assoc_opt "text" fs with
            | Some (`String s) -> s
            | _ -> fail "no text")
        | _ -> fail "shape"
      in
      let payload = Yojson.Safe.from_string text in
      match get_in payload [ "value_repr" ] with
      | `String "49" -> ()
      | _ -> fail "host:local did not share state with host omitted")

let text_of resp =
  match get_in resp [ "result"; "content" ] with
  | `List [ `Assoc fs ] -> (
      match List.assoc_opt "text" fs with
      | Some (`String s) -> s
      | _ -> fail "no text in content")
  | _ -> fail "content shape"

let test_eval_batch () =
  with_server (fun ic oc ->
      let call ?id sources =
        let id = Option.value ~default:20 id in
        let params =
          `Assoc
            [
              ("name", `String "eval_batch");
              ( "arguments",
                `Assoc
                  [
                    ( "sources",
                      `List
                        (List.map (fun s -> `String s) sources) );
                  ] );
            ]
        in
        Mcp.Rpc.write_message oc (request id "tools/call" ~params ());
        read_response_id ic
      in
      (* Three sources all succeed; bindings carry across the batch. *)
      let r_ok = call [ "let bx = 1;;"; "let by = bx + 2;;"; "by * 10;;" ] in
      let payload_ok = Yojson.Safe.from_string (text_of r_ok) in
      (match get_in payload_ok [ "stopped_on_error" ] with
       | `Bool false -> ()
       | _ -> fail "all-ok: stopped_on_error should be false");
      (match get_in payload_ok [ "results" ] with
       | `List results when List.length results = 3 ->
           let last = List.nth results 2 in
           (match get_in last [ "value_repr" ] with
            | `String "30" -> ()
            | _ -> fail "all-ok: last value_repr != 30");
           (match get_in last [ "error" ] with
            | `Null -> ()
            | _ -> fail "all-ok: unexpected error on last result")
       | `List l ->
           Printf.printf "FAIL all-ok: got %d results\n" (List.length l);
           exit 1
       | _ -> fail "all-ok: results shape");
      (* Second of three errors; stop early. *)
      let r_err =
        call ~id:21
          [ "let bz = 100;;"; "let bad = 1 + true;;"; "bz * 2;;" ]
      in
      let payload_err = Yojson.Safe.from_string (text_of r_err) in
      (match get_in payload_err [ "stopped_on_error" ] with
       | `Bool true -> ()
       | _ -> fail "err-mid: stopped_on_error should be true");
      (match get_in payload_err [ "results" ] with
       | `List results when List.length results = 2 ->
           let last = List.nth results 1 in
           (match get_in last [ "error"; "phase" ] with
            | `String "typecheck" -> ()
            | _ -> fail "err-mid: expected typecheck error on second result")
       | `List l ->
           Printf.printf "FAIL err-mid: got %d results\n" (List.length l);
           exit 1
       | _ -> fail "err-mid: results shape");
      (* Missing sources -> isError. *)
      let r_missing =
        let params =
          `Assoc
            [
              ("name", `String "eval_batch");
              ("arguments", `Assoc []);
            ]
        in
        Mcp.Rpc.write_message oc (request 22 "tools/call" ~params ());
        read_response_id ic
      in
      (match get_in r_missing [ "result"; "isError" ] with
       | `Bool true -> ()
       | _ -> fail "missing sources: expected isError true");
      (* Empty array -> isError. *)
      let r_empty = call ~id:23 [] in
      (match get_in r_empty [ "result"; "isError" ] with
       | `Bool true -> ()
       | _ -> fail "empty sources: expected isError true");
      (* Non-string element -> isError. *)
      let r_bad =
        let params =
          `Assoc
            [
              ("name", `String "eval_batch");
              ( "arguments",
                `Assoc [ ("sources", `List [ `String "1;;"; `Int 7 ]) ] );
            ]
        in
        Mcp.Rpc.write_message oc (request 24 "tools/call" ~params ());
        read_response_id ic
      in
      (match get_in r_bad [ "result"; "isError" ] with
       | `Bool true -> ()
       | _ -> fail "non-string element: expected isError true");
      ())

let () =
  let spill_dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "topup-mcp-test-spill-%d" (Unix.getpid ()))
  in
  Unix.putenv "TOPUP_SPILL_DIR" spill_dir;
  Unix.putenv "TOPUP_HOSTS_FILE" "off";
  test_rpc_roundtrip ();
  test_initialize_list_call ();
  test_initialize_has_instructions ();
  test_unknown_host_errors ();
  test_host_local_aliases ();
  test_eval_batch ();
  let _ : Yojson.Safe.t list = Mcp.Tools.descriptors in
  print_endline "test_mcp: ok"
