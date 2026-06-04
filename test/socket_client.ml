let die msg =
  prerr_endline msg;
  exit 1

let connect path =
  let sock = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  (try Unix.connect sock (Unix.ADDR_UNIX path)
   with Unix.Unix_error (err, _, _) ->
     die ("connect " ^ path ^ ": " ^ Unix.error_message err));
  (Unix.in_channel_of_descr sock, Unix.out_channel_of_descr sock)

let send_line oc s =
  output_string oc s;
  output_char oc '\n';
  flush oc

let recv_line ic =
  match input_line ic with
  | line -> line
  | exception End_of_file -> die "server closed connection"

let close_socket ic oc =
  (try close_out oc with _ -> ());
  (try close_in ic with _ -> ())

let get_field j key =
  match j with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let envelope ~name ~args : Yojson.Safe.t =
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("id", `Int 1);
      ("method", `String "tools/call");
      ( "params",
        `Assoc [ ("name", `String name); ("arguments", args) ] );
    ]

let extract_text response =
  let result =
    match get_field response "result" with
    | Some r -> r
    | None -> (
        match get_field response "error" with
        | Some (`Assoc fs) ->
            let msg =
              match List.assoc_opt "message" fs with
              | Some (`String s) -> s
              | _ -> "(no message)"
            in
            die ("ERROR: " ^ msg)
        | _ -> die "ERROR: malformed response")
  in
  match get_field result "content" with
  | Some (`List (`Assoc fs :: _)) -> (
      match List.assoc_opt "text" fs with
      | Some (`String s) -> s
      | _ -> die "ERROR: content[0].text missing")
  | _ -> die "ERROR: no content"

let print_eval_value response =
  let payload = Yojson.Safe.from_string (extract_text response) in
  match get_field payload "error" with
  | Some (`Assoc fs) ->
      let msg =
        match List.assoc_opt "message" fs with
        | Some (`String s) -> s
        | _ -> "(no message)"
      in
      print_endline ("ERROR: " ^ msg)
  | _ -> (
      match get_field payload "value_repr" with
      | Some (`String s) -> print_endline s
      | Some `Null | None -> print_endline ""
      | Some other -> print_endline (Yojson.Safe.to_string other))

let print_env_list response =
  let payload = Yojson.Safe.from_string (extract_text response) in
  match payload with
  | `List items ->
      let entries =
        List.filter_map
          (fun item ->
            match (get_field item "name", get_field item "type") with
            | Some (`String n), Some (`String ty) -> Some (n, ty)
            | _ -> None)
          items
      in
      let sorted = List.sort (fun (a, _) (b, _) -> compare a b) entries in
      if sorted = [] then print_endline "(empty)"
      else List.iter (fun (n, ty) -> Printf.printf "%s : %s\n" n ty) sorted
  | _ -> die "ERROR: env payload is not a list"

let print_lookup response =
  let payload = Yojson.Safe.from_string (extract_text response) in
  match payload with
  | `Null -> print_endline "(not found)"
  | _ -> (
      match (get_field payload "name", get_field payload "type") with
      | Some (`String n), Some (`String ty) -> Printf.printf "%s : %s\n" n ty
      | _ -> die "ERROR: lookup payload missing name/type")

let print_reset response =
  let text = extract_text response in
  print_endline text

let print_load response =
  let payload = Yojson.Safe.from_string (extract_text response) in
  match get_field payload "error" with
  | Some (`Assoc fs) ->
      let msg =
        match List.assoc_opt "message" fs with
        | Some (`String s) -> s
        | _ -> "(no message)"
      in
      print_endline ("ERROR: " ^ msg)
  | _ -> print_endline "ok"

let print_checkpoint response =
  let text = extract_text response in
  match Yojson.Safe.from_string text with
  | exception _ -> print_endline text
  | payload -> (
      match get_field payload "ok" with
      | Some (`Bool true) -> print_endline "ok"
      | _ -> print_endline text)

let result_is_error response =
  match get_field response "result" with
  | Some (`Assoc fs) -> List.assoc_opt "isError" fs = Some (`Bool true)
  | _ -> false

let print_compile response =
  let text = extract_text response in
  if result_is_error response then print_endline ("ERROR: " ^ text)
  else
    match Yojson.Safe.from_string text with
    | exception _ -> print_endline text
    | payload -> (
        match get_field payload "ok" with
        | Some (`Bool true) -> (
            match get_field payload "binary_path" with
            | Some (`String p) -> Printf.printf "ok %s\n" p
            | _ -> print_endline "ok")
        | _ -> (
            match get_field payload "build_log" with
            | Some (`String log) -> print_endline ("BUILD FAILED:\n" ^ log)
            | _ -> print_endline "BUILD FAILED"))

let print_restore response =
  let text = extract_text response in
  if result_is_error response then print_endline ("ERROR: " ^ text)
  else
    match Yojson.Safe.from_string text with
    | exception _ -> print_endline text
    | payload -> (
        match get_field payload "error" with
        | Some (`Assoc fs) ->
            let msg =
              match List.assoc_opt "message" fs with
              | Some (`String s) -> s
              | _ -> "(no message)"
            in
            print_endline ("ERROR: " ^ msg)
        | _ -> print_endline "ok")

let do_call ~path ~name ~args ~handle =
  let ic, oc = connect path in
  send_line oc (Yojson.Safe.to_string (envelope ~name ~args));
  let response = Yojson.Safe.from_string (recv_line ic) in
  handle response;
  close_socket ic oc

let () =
  match Array.to_list Sys.argv with
  | [ _; path; "request"; line ] ->
      let ic, oc = connect path in
      send_line oc line;
      print_endline (recv_line ic);
      close_socket ic oc
  | [ _; path; "eval"; source ] ->
      do_call ~path ~name:"eval"
        ~args:(`Assoc [ ("source", `String source) ])
        ~handle:print_eval_value
  | [ _; path; "env" ] ->
      do_call ~path ~name:"env" ~args:(`Assoc []) ~handle:print_env_list
  | [ _; path; "env"; filter ] ->
      do_call ~path ~name:"env"
        ~args:(`Assoc [ ("filter", `String filter) ])
        ~handle:print_env_list
  | [ _; path; "lookup"; name ] ->
      do_call ~path ~name:"lookup"
        ~args:(`Assoc [ ("name", `String name) ])
        ~handle:print_lookup
  | [ _; path; "reset" ] ->
      do_call ~path ~name:"reset" ~args:(`Assoc []) ~handle:print_reset
  | [ _; path; "load"; cma ] ->
      do_call ~path ~name:"load"
        ~args:(`Assoc [ ("path", `String cma) ])
        ~handle:print_load
  | [ _; path; "checkpoint"; label ] ->
      do_call ~path ~name:"checkpoint"
        ~args:(`Assoc [ ("label", `String label) ])
        ~handle:print_checkpoint
  | [ _; path; "restore"; label ] ->
      do_call ~path ~name:"restore"
        ~args:(`Assoc [ ("label", `String label) ])
        ~handle:print_restore
  | [ _; path; "compile"; entry; out ] ->
      do_call ~path ~name:"compile_to_binary"
        ~args:
          (`Assoc [ ("entry", `String entry); ("out", `String out) ])
        ~handle:print_compile
  | [ _; path; "compile"; entry; out; libs ] ->
      let library_names =
        if libs = "" then []
        else String.split_on_char ',' libs
      in
      do_call ~path ~name:"compile_to_binary"
        ~args:
          (`Assoc
            [
              ("entry", `String entry);
              ("out", `String out);
              ( "libraries",
                `List (List.map (fun s -> `String s) library_names) );
            ])
        ~handle:print_compile
  | _ ->
      prerr_endline "usage:";
      prerr_endline
        "  socket_client.exe <path> request <json-line>";
      prerr_endline "  socket_client.exe <path> eval <source>";
      prerr_endline "  socket_client.exe <path> env [filter]";
      prerr_endline "  socket_client.exe <path> lookup <name>";
      prerr_endline "  socket_client.exe <path> reset";
      prerr_endline "  socket_client.exe <path> load <cma-path>";
      prerr_endline "  socket_client.exe <path> checkpoint <label>";
      prerr_endline "  socket_client.exe <path> restore <label>";
      prerr_endline
        "  socket_client.exe <path> compile <entry> <out-dir> [libs-csv]";
      exit 2
