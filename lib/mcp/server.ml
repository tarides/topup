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

let initialize_result registry pool : Yojson.Safe.t =
  let instructions =
    let hosts = Host_registry.instructions_text registry in
    let sessions = Session_pool.instructions_text pool in
    match sessions with
    | "" -> hosts
    | s ->
        let sep = if String.length hosts > 0 && hosts.[String.length hosts - 1] = '\n' then "" else "\n" in
        hosts ^ sep ^ s
  in
  `Assoc
    [
      ("protocolVersion", `String protocol_version);
      ("capabilities", `Assoc [ ("tools", `Assoc []) ]);
      ( "serverInfo",
        `Assoc
          [ ("name", `String server_name); ("version", `String server_version) ]
      );
      ("instructions", `String instructions);
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

let handle_request ~session ~registry ~pool ~default_host ~id ~meth ~params :
    Yojson.Safe.t =
  match meth with
  | "initialize" -> json_result id (initialize_result registry pool)
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
              | "start_session" | "restart_session" | "update_host"
              | "start_local_session" | "restart_local_session"
              | "update_local_session" ->
                  args
              | _ -> inject_default_host ~default_host args
            in
            json_result id (Tools.dispatch session registry pool name args)
      | _ -> json_error ~code:(-32602) ~message:"invalid params" id)
  | _ -> json_error ~code:(-32601) ~message:("method not found: " ^ meth) id

let handle_notification ~session ~registry ~pool ~default_host ~meth ~params =
  match meth with
  | "notifications/cancelled" -> (
      let host_field =
        match params with
        | `Assoc fields -> (
            match List.assoc_opt "host" fields with
            | Some (`String "") | Some (`String "local") | None -> None
            | Some (`String h) -> Some h
            | _ -> None)
        | _ -> None
      in
      let session_field =
        match params with
        | `Assoc fields -> (
            match List.assoc_opt "session" fields with
            | Some (`String "") | Some (`String "local") | None -> None
            | Some (`String s) -> Some s
            | _ -> None)
        | _ -> None
      in
      let cancel_msg : Yojson.Safe.t =
        `Assoc
          [
            ("jsonrpc", `String "2.0");
            ("method", `String "notifications/cancelled");
            ("params", `Assoc []);
          ]
      in
      match (host_field, session_field) with
      | Some _, Some _ -> ()
      | None, Some s -> (
          match Session_pool.live pool s with
          | None -> ()
          | Some ls -> Local_session.notify ls cancel_msg)
      | Some h, None -> (
          match Host_registry.live registry h with
          | None -> ()
          | Some rh -> Remote_host.notify rh cancel_msg)
      | None, None -> (
          match default_host with
          | None -> Topup.Session.cancel session
          | Some host -> (
              match Host_registry.live registry host with
              | None -> ()
              | Some rh -> Remote_host.notify rh cancel_msg)))
  | _ -> ()

(* Tools that touch [session] (the in-process Toploop). Held under
   [eval_mu] in the channel's [on_request] so that a back-channel
   blob call originated from inside [eval] can interleave on the
   reader thread without a second worker tripping into Toploop
   reentrancy. *)
let session_touching_tool = function
  | "eval" | "eval_batch" | "env" | "lookup" | "load"
  | "reset" | "checkpoint" | "restore" | "compile_to_binary" -> true
  | _ -> false

let needs_eval_mu meth params =
  if meth <> "tools/call" then false
  else
    match params with
    | `Assoc fs -> (
        match List.assoc_opt "name" fs with
        | Some (`String name) -> session_touching_tool name
        | _ -> false)
    | _ -> false

(* Build a [tools/call] request envelope. The [id] is a placeholder;
   {!Channel.request} overwrites it. *)
let build_tools_call_request ~name ~args : Yojson.Safe.t =
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("id", `Int 0);
      ("method", `String "tools/call");
      ( "params",
        `Assoc
          [ ("name", `String name); ("arguments", args) ] );
    ]

(* Parse a [tools/call] response: extract [result.content[0].text] as
   raw text, interpret as JSON, surface [isError=true] as a [Failure]. *)
let parse_back_channel_response ~label (resp : Yojson.Safe.t) :
    (Yojson.Safe.t, string) result =
  match resp with
  | `Assoc fields -> (
      match List.assoc_opt "result" fields with
      | None -> (
          match List.assoc_opt "error" fields with
          | Some (`Assoc err_fields) ->
              let msg =
                match List.assoc_opt "message" err_fields with
                | Some (`String s) -> s
                | _ -> "unknown back-channel error"
              in
              Error (label ^ ": " ^ msg)
          | _ -> Error (label ^ ": malformed back-channel response"))
      | Some (`Assoc result_fields) -> (
          let is_error =
            match List.assoc_opt "isError" result_fields with
            | Some (`Bool b) -> b
            | _ -> false
          in
          let text =
            match List.assoc_opt "content" result_fields with
            | Some (`List (`Assoc cf :: _)) -> (
                match List.assoc_opt "text" cf with
                | Some (`String s) -> Some s
                | _ -> None)
            | _ -> None
          in
          match text with
          | None -> Error (label ^ ": malformed back-channel response")
          | Some s ->
              if is_error then Error (label ^ ": " ^ s)
              else
                try Ok (Yojson.Safe.from_string s)
                with Yojson.Json_error msg -> Error (label ^ ": " ^ msg))
      | Some _ -> Error (label ^ ": malformed back-channel response"))
  | _ -> Error (label ^ ": malformed back-channel response")

let muxed_io ch : Topup_runtime.io_hook =
  let read path =
    let args = `Assoc [ ("path", `String path) ] in
    let req = build_tools_call_request ~name:"_send_blob" ~args in
    let resp = Channel.request ch req in
    match parse_back_channel_response ~label:"Topup.read_back" resp with
    | Error msg -> failwith msg
    | Ok payload -> (
        let data =
          match payload with
          | `Assoc fs -> (
              match List.assoc_opt "data" fs with
              | Some (`String s) -> Some s
              | _ -> None)
          | _ -> None
        in
        match data with
        | None -> failwith "Topup.read_back: response missing 'data'"
        | Some s -> (
            match Base64.decode s with
            | Ok bytes -> Bytes.of_string bytes
            | Error (`Msg msg) ->
                failwith ("Topup.read_back: base64 decode: " ^ msg)))
  in
  let write path bytes =
    let args =
      `Assoc
        [
          ("path", `String path);
          ("data", `String (Base64.encode_string (Bytes.to_string bytes)));
        ]
    in
    let req = build_tools_call_request ~name:"_recv_blob" ~args in
    let resp = Channel.request ch req in
    match parse_back_channel_response ~label:"Topup.write_back" resp with
    | Error msg -> failwith msg
    | Ok _ -> ()
  in
  { Topup_runtime.read; write }

let run ~ic ~oc ~session ~registry ~pool ?default_host () =
  let eval_mu = Mutex.create () in
  let ch_ref : Channel.t option ref = ref None in
  let back_channel_installed = ref false in
  let install_back_channel () =
    match !ch_ref with
    | None -> ()
    | Some ch ->
        if not !back_channel_installed then begin
          Topup_runtime.install_hook (muxed_io ch);
          back_channel_installed := true
        end
  in
  let dispatch_message msg : Yojson.Safe.t =
    match msg with
    | `Assoc fields ->
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
        let tool_name =
          if meth_opt = Some "tools/call" then
            match params with
            | `Assoc fs -> (
                match List.assoc_opt "name" fs with
                | Some (`String s) -> s
                | _ -> "")
            | _ -> ""
          else ""
        in
        (* Hook activation: the connecting peer opts in by calling
           [_enable_back_channel] after the initialize handshake.
           That tells this side "I can dispatch _send_blob /
           _recv_blob coming back on this channel" — so a routed
           [eval] running [Topup.read_back] reaches back through
           the muxer instead of falling through to [direct_hook]. *)
        if tool_name = "_enable_back_channel" then begin
          install_back_channel ();
          let id = Option.value id_opt ~default:`Null in
          json_result id
            (`Assoc
               [
                 ("content",
                  `List
                    [
                      `Assoc
                        [
                          ("type", `String "text");
                          ("text", `String "ok");
                        ];
                    ]);
                 ("isError", `Bool false);
               ])
        end
        else
          (match (meth_opt, id_opt) with
           | Some m, Some id ->
               if needs_eval_mu m params then begin
                 Mutex.lock eval_mu;
                 let r =
                   handle_request ~session ~registry ~pool ~default_host
                     ~id ~meth:m ~params
                 in
                 Mutex.unlock eval_mu;
                 r
               end
               else
                 handle_request ~session ~registry ~pool ~default_host
                   ~id ~meth:m ~params
           | Some m, None ->
               (* Notification: never under [eval_mu] (cancel must
                  work while an eval is in flight). [Channel]
                  discards the return value. *)
               handle_notification ~session ~registry ~pool ~default_host
                 ~meth:m ~params;
               `Null
           | None, _ -> `Null)
    | _ -> `Null
  in
  let on_request msg =
    try dispatch_message msg
    with exn ->
      let id =
        match msg with
        | `Assoc fs -> (
            match List.assoc_opt "id" fs with Some j -> j | None -> `Null)
        | _ -> `Null
      in
      json_error ~code:(-32603)
        ~message:("server error: " ^ Printexc.to_string exn)
        id
  in
  let ch = Channel.create ~ic ~oc ~on_request in
  ch_ref := Some ch;
  let cleanup () =
    if !back_channel_installed then
      Topup_runtime.install_hook Topup_runtime.direct_hook;
    ch_ref := None
  in
  (match Channel.wait_closed ch with
   | () -> cleanup ()
   | exception exn ->
       cleanup ();
       raise exn)

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

let serve_unix ~path ~session ~registry ~pool ?default_host () =
  prepare_socket_path path;
  let server = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind server (Unix.ADDR_UNIX path);
  Unix.listen server 1;
  at_exit (fun () ->
      try Unix.unlink path with _ -> ());
  let exit_on signal =
    try
      Sys.set_signal signal
        (Sys.Signal_handle
           (fun _ ->
             (* [exit 0] would run at_exit handlers (including the
                socket unlink above) but with worker threads parked
                in their own [Condition.wait] loops the cleanup
                chain has been observed to hang under OCaml 5's
                threads.posix.  Unlink directly here and call
                [_exit] so the kernel reaps every thread. *)
             (try Unix.unlink path with _ -> ());
             Unix._exit 0))
    with Invalid_argument _ -> ()
  in
  exit_on Sys.sigterm;
  exit_on Sys.sighup;
  (try Sys.set_signal Sys.sigpipe Sys.Signal_ignore
   with Invalid_argument _ -> ());
  (* [Unix.select] with a short timeout instead of a bare
     [Unix.accept] so OCaml's signal handler reliably fires on
     SIGTERM/SIGHUP — when [accept] blocks with no client
     connecting, the signal lands on domain 0 but the handler
     can't run until the syscall returns. The select wakes every
     [accept_poll] seconds, giving the polling point a chance to
     dispatch the queued handler. *)
  let accept_poll = 0.5 in
  while true do
    match Unix.select [ server ] [] [] accept_poll with
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> ()
    | [], _, _ -> ()
    | _ ->
        let client, _ = Unix.accept server in
        let ic = Unix.in_channel_of_descr client in
        let oc = Unix.out_channel_of_descr client in
        (try run ~ic ~oc ~session ~registry ~pool ?default_host ()
         with _ -> ());
        (try close_in ic with _ -> ());
        (try close_out oc with _ -> ())
  done
