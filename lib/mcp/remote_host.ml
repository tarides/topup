type conn = {
  ssh : Proxy.ssh_handle option;
  sock : Unix.file_descr;
  channel : Channel.t;
}

type t = {
  host : string;
  remote_socket : string;
  mutable conn : conn option;
  mutable last_seen : string option;
  mutex : Mutex.t;
}

let default_remote_socket_for_host _host =
  match Sys.getenv_opt "HOME" with
  | Some home -> Filename.concat home ".topup/sockets/topup.sock"
  | None -> "/tmp/topup-default.sock"

let env_socket_for host =
  let key =
    "TOPUP_HOST_SOCKET_" ^ String.uppercase_ascii host
  in
  Sys.getenv_opt key

let initialize_request : Yojson.Safe.t =
  Rpc.request ~id:(`Int 0) "initialize"

let do_handshake oc ic =
  Rpc.write_message oc initialize_request;
  match Rpc.read_message ic with
  | Some j -> j
  | None -> failwith "remote: EOF during initialize"

(* Read deadline for the handshake response. Without this, a remote
   that accepts the TCP/UNIX connection but never writes back (e.g. a
   stale daemon already busy with another client) blocks [input_line]
   forever and the retry loop in [open_conn] can't make progress. The
   socket option is cleared after a successful handshake so subsequent
   send/recv cycles aren't bounded. *)
let handshake_read_timeout = 2.0

let do_handshake_bounded sock oc ic =
  (try Unix.setsockopt_float sock Unix.SO_RCVTIMEO handshake_read_timeout
   with Unix.Unix_error _ -> ());
  let clear () =
    try Unix.setsockopt_float sock Unix.SO_RCVTIMEO 0.0
    with Unix.Unix_error _ -> ()
  in
  match do_handshake oc ic with
  | j -> clear (); j
  | exception exn -> clear (); raise exn

(* Try one connect + handshake. Returns [Ok (sock, ic, oc)] on success;
   [Error msg] for retryable errors (closed socket along the way);
   raises for non-retryable errors. *)
let try_connect_and_handshake ~path =
  match Proxy.connect_with_retry ~path ~timeout:1.0 with
  | exception Failure msg -> Error msg
  | sock ->
      let ic = Unix.in_channel_of_descr sock in
      let oc = Unix.out_channel_of_descr sock in
      (match do_handshake_bounded sock oc ic with
       | _ -> Ok (sock, ic, oc)
       | exception (Failure _ | End_of_file | Sys_error _) ->
           (try Unix.close sock with _ -> ());
           Error "handshake EOF / channel closed"
       | exception (Unix.Unix_error _ | Sys_blocked_io) ->
           (try Unix.close sock with _ -> ());
           Error "handshake timed out"
       | exception exn ->
           (try Unix.close sock with _ -> ());
           raise exn)

(* The remote daemon may originate JSON-RPC requests back over the
   tunnel — today only [_send_blob] / [_recv_blob] used by
   [Topup.read_back] / [Topup.write_back] from inside a routed eval.
   These are pure file I/O against the local filesystem (where the
   chatbot lives); no session is involved. *)
let on_request (msg : Yojson.Safe.t) : Yojson.Safe.t =
  match msg with
  | `Assoc fields ->
      let id =
        match List.assoc_opt "id" fields with Some j -> j | None -> `Null
      in
      let name, args =
        match List.assoc_opt "params" fields with
        | Some (`Assoc params) ->
            let n =
              match List.assoc_opt "name" params with
              | Some (`String s) -> s
              | _ -> ""
            in
            let a =
              match List.assoc_opt "arguments" params with
              | Some j -> j
              | None -> `Assoc []
            in
            (n, a)
        | _ -> ("", `Assoc [])
      in
      (* Confine the remote peer's reach into our local filesystem. *)
      let confine_root = Blob.backchannel_confine_root () in
      let result = Blob.dispatch ?confine_root name args in
      Rpc.response ~id result
  | _ -> Rpc.error ~code:(-32600) ~message:"invalid request" `Null

(* Tell the remote daemon "I can dispatch _send_blob / _recv_blob
   on inbound requests over this channel" so it installs the muxed
   [Topup_runtime] hook for the duration of the connection. Best-
   effort: if the remote refuses (older daemon without the back
   channel), we still have a working connection — routed evals just
   can't call [Topup.read_back] on a remote-resident file. *)
let enable_back_channel_request : Yojson.Safe.t =
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("id", `Int 0);
      ("method", `String "tools/call");
      ( "params",
        `Assoc
          [
            ("name", `String "_enable_back_channel");
            ("arguments", `Assoc []);
          ] );
    ]

let build_conn ~ssh sock ic oc =
  let channel = Channel.create ~ic ~oc ~on_request in
  (try
     let _ : Yojson.Safe.t =
       Channel.request channel enable_back_channel_request
     in
     ()
   with _ -> ());
  { ssh; sock; channel }

let open_conn ~host ~remote_socket =
  match env_socket_for host with
  | Some path -> (
      (* Test hook: connect to a co-resident `topup --socket` daemon.
         The remote is fully up, so a single attempt is enough. *)
      match try_connect_and_handshake ~path with
      | Ok (sock, ic, oc) -> build_conn ~ssh:None sock ic oc
      | Error msg -> failwith ("remote " ^ host ^ ": " ^ msg))
  | None ->
      let handle = Proxy.spawn_ssh ~host ~remote_socket () in
      let deadline = Unix.gettimeofday () +. 20.0 in
      let rec attempt last_err =
        if Unix.gettimeofday () >= deadline then (
          Proxy.kill_ssh handle;
          failwith
            (Printf.sprintf
               "remote %s: timed out waiting for daemon (last: %s)"
               host last_err))
        else
          match try_connect_and_handshake ~path:handle.local_sock with
          | Ok (sock, ic, oc) -> build_conn ~ssh:(Some handle) sock ic oc
          | Error msg ->
              (try Unix.sleepf 0.1 with _ -> ());
              attempt msg
          | exception exn ->
              Proxy.kill_ssh handle;
              raise exn
      in
      attempt "no attempt yet"

let start ~host ?remote_socket () =
  (* Reject hostile host strings up front so the error surfaces
     uniformly — including on the [TOPUP_HOST_SOCKET_*] test-hook path,
     which never reaches [Proxy.spawn_ssh]'s own check. *)
  (match Proxy.validate_host host with
   | Ok () -> ()
   | Error msg -> failwith ("invalid host: " ^ msg));
  let remote_socket =
    match remote_socket with
    | Some p -> p
    | None -> default_remote_socket_for_host host
  in
  let conn = open_conn ~host ~remote_socket in
  {
    host;
    remote_socket;
    conn = Some conn;
    last_seen = None;
    mutex = Mutex.create ();
  }

let close_conn t =
  match t.conn with
  | None -> ()
  | Some c ->
      Channel.close c.channel;
      (* Channel.close closes ic/oc; the underlying socket is the same
         fd so it's already torn down. Closing it again is harmless. *)
      (try Unix.close c.sock with _ -> ());
      (match c.ssh with
       | Some handle -> Proxy.kill_ssh handle
       | None -> ());
      t.conn <- None

let close t =
  Mutex.lock t.mutex;
  close_conn t;
  Mutex.unlock t.mutex

let host t = t.host
let remote_socket t = t.remote_socket
let last_seen t = t.last_seen
let is_live t =
  match t.conn with
  | None -> false
  | Some c -> not (Channel.is_closed c.channel)

let send t (req : Yojson.Safe.t) : Yojson.Safe.t =
  Mutex.lock t.mutex;
  let conn = t.conn in
  Mutex.unlock t.mutex;
  match conn with
  | None -> failwith ("remote " ^ t.host ^ ": connection closed")
  | Some c -> (
      match Channel.request c.channel req with
      | response ->
          t.last_seen <- Some (Topup_util.iso8601_utc_now ());
          response
      | exception Failure msg ->
          (* Mark connection dead on channel-level error. *)
          Mutex.lock t.mutex;
          close_conn t;
          Mutex.unlock t.mutex;
          failwith ("remote " ^ t.host ^ ": " ^ msg)
      | exception exn ->
          Mutex.lock t.mutex;
          close_conn t;
          Mutex.unlock t.mutex;
          raise exn)

let notify t (msg : Yojson.Safe.t) : unit =
  Mutex.lock t.mutex;
  let conn = t.conn in
  Mutex.unlock t.mutex;
  match conn with
  | None -> ()
  | Some c -> Channel.notify c.channel msg

let restart t =
  Mutex.lock t.mutex;
  close_conn t;
  (match open_conn ~host:t.host ~remote_socket:t.remote_socket with
   | conn -> t.conn <- Some conn
   | exception exn ->
       Mutex.unlock t.mutex;
       raise exn);
  Mutex.unlock t.mutex
