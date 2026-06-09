type subproc = {
  pid : int;
  socket_path : string;
}

type conn = {
  proc : subproc option;
  sock : Unix.file_descr;
  ic : in_channel;
  oc : out_channel;
}

type t = {
  name : string;
  local_socket : string;
  prewarm : string option;
  mutable conn : conn option;
  mutable next_id : int;
  mutable last_seen : string option;
  mutex : Mutex.t;
}

let initialize_request : Yojson.Safe.t =
  Rpc.request ~id:(`Int 0) "initialize"

let do_handshake oc ic =
  Rpc.write_message oc initialize_request;
  match Rpc.read_message ic with
  | Some j -> j
  | None -> failwith "local session: EOF during initialize"

let env_socket_for name =
  let key = "TOPUP_SESSION_SOCKET_" ^ String.uppercase_ascii name in
  Sys.getenv_opt key

let sanitize_name name =
  let buf = Buffer.create (String.length name) in
  String.iter
    (fun c ->
      match c with
      | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' ->
          Buffer.add_char buf c
      | _ -> Buffer.add_char buf '_')
    name;
  Buffer.contents buf

let default_local_socket name =
  Random.self_init ();
  let hex = Proxy.random_hex 16 in
  Printf.sprintf "/tmp/topup-session-%s-%s.sock" (sanitize_name name) hex

let spawn_subprocess ~name ~socket_path =
  let exe = Sys.executable_name in
  let dev_null_in = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0o600 in
  let dev_null_out = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0o600 in
  let argv = [| exe; "--socket"; socket_path |] in
  let pid =
    try
      Unix.create_process exe argv dev_null_in dev_null_out dev_null_out
    with exn ->
      (try Unix.close dev_null_in with _ -> ());
      (try Unix.close dev_null_out with _ -> ());
      raise exn
  in
  (try Unix.close dev_null_in with _ -> ());
  (try Unix.close dev_null_out with _ -> ());
  ignore name;
  { pid; socket_path }

let kill_subprocess proc =
  (try Unix.kill proc.pid Sys.sigterm with _ -> ());
  let waited = ref 0.0 in
  let interval = 0.05 in
  let deadline = 1.0 in
  let alive () =
    try
      match Unix.waitpid [ Unix.WNOHANG ] proc.pid with
      | 0, _ -> true
      | _ -> false
    with _ -> false
  in
  while alive () && !waited < deadline do
    Unix.sleepf interval;
    waited := !waited +. interval
  done;
  if alive () then begin
    (try Unix.kill proc.pid Sys.sigkill with _ -> ());
    (try ignore (Unix.waitpid [] proc.pid) with _ -> ())
  end;
  (try Unix.unlink proc.socket_path
   with Unix.Unix_error (Unix.ENOENT, _, _) -> () | _ -> ())

let try_connect_and_handshake ~path =
  match Proxy.connect_with_retry ~path ~timeout:1.0 with
  | exception Failure msg -> Error msg
  | sock -> (
      let ic = Unix.in_channel_of_descr sock in
      let oc = Unix.out_channel_of_descr sock in
      match do_handshake oc ic with
      | _ -> Ok (sock, ic, oc)
      | exception (Failure _ | End_of_file | Sys_error _) ->
          (try Unix.close sock with _ -> ());
          Error "handshake EOF / channel closed"
      | exception exn ->
          (try Unix.close sock with _ -> ());
          raise exn)

(* Send a tools/call eval request over the freshly-opened connection
   to evaluate the prewarm phrase. Returns Ok () on success, Error msg
   on any failure (eval error, malformed response, transport error). *)
let run_prewarm ~oc ~ic ~name ~prewarm_path =
  let source = Printf.sprintf "#use %S;;" prewarm_path in
  let req : Yojson.Safe.t =
    `Assoc
      [
        ("jsonrpc", `String "2.0");
        ("id", `Int 1);
        ("method", `String "tools/call");
        ( "params",
          `Assoc
            [
              ("name", `String "eval");
              ("arguments", `Assoc [ ("source", `String source) ]);
            ] );
      ]
  in
  match
    Rpc.write_message oc req;
    Rpc.read_message ic
  with
  | exception exn ->
      Error
        (Printf.sprintf "prewarm %s: transport error: %s" name
           (Printexc.to_string exn))
  | None -> Error (Printf.sprintf "prewarm %s: EOF awaiting response" name)
  | Some (`Assoc fields) -> (
      match List.assoc_opt "result" fields with
      | None -> Error (Printf.sprintf "prewarm %s: no result in response" name)
      | Some (`Assoc rfs) -> (
          let is_error =
            match List.assoc_opt "isError" rfs with
            | Some (`Bool b) -> b
            | _ -> false
          in
          let text =
            match List.assoc_opt "content" rfs with
            | Some (`List [ `Assoc cfs ]) -> (
                match List.assoc_opt "text" cfs with
                | Some (`String s) -> Some s
                | _ -> None)
            | _ -> None
          in
          if is_error then
            Error
              (Printf.sprintf "prewarm %s: %s" name
                 (match text with Some s -> s | None -> "tool error"))
          else
            match text with
            | None -> Ok ()
            | Some s -> (
                match Yojson.Safe.from_string s with
                | exception _ -> Ok ()
                | `Assoc payload -> (
                    match List.assoc_opt "error" payload with
                    | Some `Null | None -> Ok ()
                    | Some (`Assoc err_fields) ->
                        let msg =
                          match List.assoc_opt "message" err_fields with
                          | Some (`String s) -> s
                          | _ -> "unknown error"
                        in
                        Error (Printf.sprintf "prewarm %s: %s" name msg)
                    | _ -> Ok ())
                | _ -> Ok ()))
      | Some _ -> Error (Printf.sprintf "prewarm %s: malformed result" name))
  | Some _ -> Error (Printf.sprintf "prewarm %s: malformed response" name)

(* Run the optional prewarm phrase; on failure run [on_fail] (socket
   close, plus subprocess kill when we own one) before re-raising. *)
let apply_prewarm ~name ~prewarm ~oc ~ic ~on_fail =
  match prewarm with
  | None -> ()
  | Some pre -> (
      match run_prewarm ~oc ~ic ~name ~prewarm_path:pre with
      | Ok () -> ()
      | Error msg ->
          on_fail ();
          failwith msg)

let open_conn ~name ~local_socket ~prewarm =
  match env_socket_for name with
  | Some path ->
      let sock = Proxy.connect_with_retry ~path ~timeout:10.0 in
      let ic = Unix.in_channel_of_descr sock in
      let oc = Unix.out_channel_of_descr sock in
      let _ = do_handshake oc ic in
      apply_prewarm ~name ~prewarm ~oc ~ic ~on_fail:(fun () ->
          try Unix.close sock with _ -> ());
      { proc = None; sock; ic; oc }
  | None ->
      let proc = spawn_subprocess ~name ~socket_path:local_socket in
      let deadline = Unix.gettimeofday () +. 20.0 in
      let rec attempt last_err =
        if Unix.gettimeofday () >= deadline then begin
          kill_subprocess proc;
          failwith
            (Printf.sprintf
               "local session %s: timed out waiting for daemon (last: %s)"
               name last_err)
        end
        else
          match try_connect_and_handshake ~path:local_socket with
          | Ok (sock, ic, oc) ->
              apply_prewarm ~name ~prewarm ~oc ~ic ~on_fail:(fun () ->
                  (try Unix.close sock with _ -> ());
                  kill_subprocess proc);
              { proc = Some proc; sock; ic; oc }
          | Error msg ->
              (try Unix.sleepf 0.1 with _ -> ());
              attempt msg
          | exception exn ->
              kill_subprocess proc;
              raise exn
      in
      attempt "no attempt yet"

let start ~name ?local_socket ?prewarm () =
  let local_socket =
    match local_socket with
    | Some p -> p
    | None -> default_local_socket name
  in
  let conn = open_conn ~name ~local_socket ~prewarm in
  {
    name;
    local_socket;
    prewarm;
    conn = Some conn;
    next_id = 1;
    last_seen = None;
    mutex = Mutex.create ();
  }

let close_conn t =
  match t.conn with
  | None -> ()
  | Some c ->
      (try close_in c.ic with _ -> ());
      (try close_out c.oc with _ -> ());
      (try Unix.close c.sock with _ -> ());
      (match c.proc with
       | Some proc -> kill_subprocess proc
       | None -> ());
      t.conn <- None

let close t =
  Mutex.lock t.mutex;
  close_conn t;
  Mutex.unlock t.mutex

let name t = t.name
let local_socket t = t.local_socket
let prewarm t = t.prewarm
let last_seen t = t.last_seen
let is_live t = t.conn <> None

let set_id (req : Yojson.Safe.t) id : Yojson.Safe.t =
  match req with
  | `Assoc fields ->
      let fields' =
        List.map
          (fun ((k, _) as kv) -> if k = "id" then (k, `Int id) else kv)
          fields
      in
      let has_id = List.exists (fun (k, _) -> k = "id") fields in
      let fields' = if has_id then fields' else ("id", `Int id) :: fields' in
      `Assoc fields'
  | _ -> req

let send t (req : Yojson.Safe.t) : Yojson.Safe.t =
  Mutex.lock t.mutex;
  match t.conn with
  | None ->
      Mutex.unlock t.mutex;
      failwith ("local session " ^ t.name ^ ": connection closed")
  | Some c -> (
      let id = t.next_id in
      t.next_id <- id + 1;
      let req' = set_id req id in
      (try Rpc.write_message c.oc req'
       with exn ->
         close_conn t;
         Mutex.unlock t.mutex;
         raise exn);
      match Rpc.read_message c.ic with
      | None ->
          close_conn t;
          Mutex.unlock t.mutex;
          failwith ("local session " ^ t.name ^ ": EOF awaiting response")
      | Some j ->
          t.last_seen <- Some (Topup_util.iso8601_utc_now ());
          Mutex.unlock t.mutex;
          j
      | exception exn ->
          close_conn t;
          Mutex.unlock t.mutex;
          raise exn)

let notify t (msg : Yojson.Safe.t) : unit =
  Mutex.lock t.mutex;
  (match t.conn with
   | None -> ()
   | Some c -> (
       try Rpc.write_message c.oc msg with _ -> close_conn t));
  Mutex.unlock t.mutex

let restart t =
  Mutex.lock t.mutex;
  close_conn t;
  (match
     open_conn ~name:t.name ~local_socket:t.local_socket ~prewarm:t.prewarm
   with
   | conn ->
       t.conn <- Some conn;
       t.next_id <- 1
   | exception exn ->
       Mutex.unlock t.mutex;
       raise exn);
  Mutex.unlock t.mutex
