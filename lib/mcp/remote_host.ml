type conn = {
  ssh : Proxy.ssh_handle option;
  sock : Unix.file_descr;
  ic : in_channel;
  oc : out_channel;
}

type t = {
  host : string;
  remote_socket : string;
  mutable conn : conn option;
  mutable next_id : int;
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

let iso8601_utc_now () =
  let t = Unix.gettimeofday () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec

let initialize_request : Yojson.Safe.t =
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("id", `Int 0);
      ("method", `String "initialize");
    ]

let do_handshake oc ic =
  Rpc.write_message oc initialize_request;
  match Rpc.read_message ic with
  | Some j -> j
  | None -> failwith "remote: EOF during initialize"

(* Try one connect + handshake. Returns [Ok (sock, ic, oc)] on success;
   [Error msg] for retryable errors (closed socket along the way);
   raises for non-retryable errors. *)
let try_connect_and_handshake ~path =
  match Proxy.connect_with_retry ~path ~timeout:1.0 with
  | exception Failure msg -> Error msg
  | sock ->
      let ic = Unix.in_channel_of_descr sock in
      let oc = Unix.out_channel_of_descr sock in
      (match do_handshake oc ic with
       | _ -> Ok (sock, ic, oc)
       | exception (Failure _ | End_of_file | Sys_error _) ->
           (try Unix.close sock with _ -> ());
           Error "handshake EOF / channel closed"
       | exception exn ->
           (try Unix.close sock with _ -> ());
           raise exn)

let open_conn ~host ~remote_socket =
  match env_socket_for host with
  | Some path ->
      (* Test hook: connect to a co-resident `topup --socket` daemon.
         The remote is fully up, so a single attempt is enough. *)
      let sock = Proxy.connect_with_retry ~path ~timeout:10.0 in
      let ic = Unix.in_channel_of_descr sock in
      let oc = Unix.out_channel_of_descr sock in
      let _ = do_handshake oc ic in
      { ssh = None; sock; ic; oc }
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
          | Ok (sock, ic, oc) -> { ssh = Some handle; sock; ic; oc }
          | Error msg ->
              (try Unix.sleepf 0.1 with _ -> ());
              attempt msg
          | exception exn ->
              Proxy.kill_ssh handle;
              raise exn
      in
      attempt "no attempt yet"

let start ~host ?remote_socket () =
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
      failwith ("remote " ^ t.host ^ ": connection closed")
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
          failwith ("remote " ^ t.host ^ ": EOF awaiting response")
      | Some j ->
          t.last_seen <- Some (iso8601_utc_now ());
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
   | Some c ->
       (try Rpc.write_message c.oc msg
        with _ -> close_conn t));
  Mutex.unlock t.mutex

let restart t =
  Mutex.lock t.mutex;
  close_conn t;
  (match open_conn ~host:t.host ~remote_socket:t.remote_socket with
   | conn ->
       t.conn <- Some conn;
       t.next_id <- 1
   | exception exn ->
       Mutex.unlock t.mutex;
       raise exn);
  Mutex.unlock t.mutex
