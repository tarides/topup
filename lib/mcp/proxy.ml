let copy_loop ?on_eof ~src ~dst () =
  let buf = Bytes.create 4096 in
  let rec write_all off remaining =
    if remaining = 0 then ()
    else
      match Unix.write dst buf off remaining with
      | exception Unix.Unix_error (Unix.EINTR, _, _) ->
          write_all off remaining
      | w -> write_all (off + w) (remaining - w)
  in
  let rec loop () =
    match Unix.read src buf 0 (Bytes.length buf) with
    | 0 -> (match on_eof with Some f -> ( try f () with _ -> ()) | None -> ())
    | n ->
        (try write_all 0 n with Unix.Unix_error _ -> ());
        loop ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
    | exception Unix.Unix_error _ -> ()
  in
  loop ()

let connect_with_retry ~path ~timeout =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec attempt () =
    let sock = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    match Unix.connect sock (Unix.ADDR_UNIX path) with
    | () -> sock
    | exception Unix.Unix_error ((Unix.ENOENT | Unix.ECONNREFUSED), _, _) ->
        (try Unix.close sock with _ -> ());
        if Unix.gettimeofday () >= deadline then
          failwith
            (Printf.sprintf
               "topup-mcp: timed out after %.1fs waiting for socket %s"
               timeout path)
        else (
          Unix.sleepf 0.05;
          attempt ())
    | exception Unix.Unix_error (err, _, _) ->
        (try Unix.close sock with _ -> ());
        failwith
          (Printf.sprintf "topup-mcp: connect %s: %s" path
             (Unix.error_message err))
  in
  attempt ()

let run_proxy ~socket_path ?(connect_timeout = 10.0) () =
  let sock = connect_with_retry ~path:socket_path ~timeout:connect_timeout in
  (try Sys.set_signal Sys.sigpipe Sys.Signal_ignore
   with Invalid_argument _ -> ());
  let _in_t =
    Thread.create
      (fun () ->
        copy_loop
          ~on_eof:(fun () -> Unix.shutdown sock Unix.SHUTDOWN_SEND)
          ~src:Unix.stdin ~dst:sock ())
      ()
  in
  let out_t =
    Thread.create
      (fun () -> copy_loop ~src:sock ~dst:Unix.stdout ())
      ()
  in
  Thread.join out_t;
  (try Unix.shutdown sock Unix.SHUTDOWN_ALL with _ -> ());
  (try Unix.close sock with _ -> ())

let random_hex n =
  let b = Bytes.create n in
  for i = 0 to n - 1 do
    Bytes.set b i "0123456789abcdef".[Random.bits () land 0xf]
  done;
  Bytes.unsafe_to_string b

let default_remote_socket () = "/tmp/topup-" ^ random_hex 16 ^ ".sock"
let local_socket () = "/tmp/topup-local-" ^ random_hex 16 ^ ".sock"

(* [host] is handed to ssh(1) as an argv token. ssh treats a token
   beginning with '-' as an option, so an unvalidated host like
   "-oProxyCommand=touch /tmp/pwned" is argument injection that runs a
   command on the *local* machine. Restrict to a charset that admits
   [user@host] and rejects anything ssh could reinterpret (leading '-',
   whitespace, shell metacharacters, NUL, newline). *)
let valid_host_char c =
  match c with
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' | '@' -> true
  | _ -> false

let validate_host host =
  if host = "" then Error "host must be non-empty"
  else if host.[0] = '-' then
    Error "host must not begin with '-' (ssh would parse it as an option)"
  else if not (String.for_all valid_host_char host) then
    Error "host may only contain [A-Za-z0-9._@-]"
  else Ok ()

(* [remote_socket] is [Filename.quote]d into the remote shell command, so
   shell injection is already handled; this guards against a NUL (which
   would truncate the argv token in [create_process]) or a newline, and
   insists on an absolute path so the remote [mkdir -p]/socket bind land
   where intended. *)
let validate_remote_socket path =
  if path = "" then Error "remote_socket must be non-empty"
  else if String.exists (fun c -> c = '\000' || c = '\n' || c = '\r') path
  then Error "remote_socket must not contain NUL or newline"
  else if Filename.is_relative path then
    Error "remote_socket must be an absolute path"
  else Ok ()

type ssh_handle = {
  ssh_pid : int;
  local_sock : string;
  remote_sock : string;
  stdin_write : Unix.file_descr;
      (** Held by the parent for the lifetime of the tunnel.
          Closing it (via {!kill_ssh} or on parent exit) sends EOF
          along ssh's stdin → the remote `cat` wrapper exits → the
          remote `topup --socket` daemon gets SIGTERM and unlinks
          its socket. *)
}

let spawn_ssh ~host ?remote_socket () =
  Random.self_init ();
  let remote_sock =
    match remote_socket with Some p -> p | None -> default_remote_socket ()
  in
  (match validate_host host with
   | Ok () -> ()
   | Error msg -> failwith ("invalid host: " ^ msg));
  (match validate_remote_socket remote_sock with
   | Ok () -> ()
   | Error msg -> failwith ("invalid remote_socket: " ^ msg));
  let local_sock = local_socket () in
  let dev_null = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0o600 in
  let stdin_read, stdin_write = Unix.pipe ~cloexec:true () in
  let remote_dir = Filename.dirname remote_sock in
  (* Heartbeat-pipe wrapper. The remote shell launches `topup --socket`
     in the background and blocks on `cat` reading from the channel's
     stdin. When the local side closes [stdin_write] (or this process
     exits), `cat` reads EOF, the EXIT trap fires and SIGTERMs the
     daemon, which runs its at_exit and unlinks the socket file.

     `topup`'s stdin/stdout/stderr are redirected to /dev/null. Without
     this, ssh's channel-stdout / channel-stderr stay open through the
     daemon's inherited fds, so ssh refuses to exit even after the
     remote shell terminates — and the local side hangs. The cost is
     no remote-side error visibility once the daemon is launched. *)
  let remote_cmd =
    Printf.sprintf
      "mkdir -p %s; \
       topup --socket %s </dev/null >/dev/null 2>&1 & \
       PID=$!; \
       trap 'kill -TERM $PID 2>/dev/null; wait $PID 2>/dev/null' EXIT; \
       cat >/dev/null"
      (Filename.quote remote_dir) (Filename.quote remote_sock)
  in
  let argv =
    [|
      "ssh";
      "-o"; "ExitOnForwardFailure=yes";
      "-o"; "ServerAliveInterval=30";
      "-L"; Printf.sprintf "%s:%s" local_sock remote_sock;
      (* [--] stops ssh option parsing; combined with [validate_host]'s
         leading-'-' rejection this is belt-and-suspenders against argv
         injection through the host token. *)
      "--";
      host;
      remote_cmd;
    |]
  in
  let ssh_pid =
    Unix.create_process "ssh" argv stdin_read dev_null Unix.stderr
  in
  (try Unix.close stdin_read with _ -> ());
  (try Unix.close dev_null with _ -> ());
  { ssh_pid; local_sock; remote_sock; stdin_write }

let kill_ssh handle =
  (* Close [stdin_write] first so ssh sees EOF on its stdin and
     forwards the channel close to the remote, which lets the
     remote `cat` wrapper exit and SIGTERM the daemon. Only
     SIGTERM the ssh client itself as a fallback if it hasn't
     exited on its own within a short window — the goal is to give
     the channel-close time to propagate before yanking the
     plug. *)
  (try Unix.close handle.stdin_write with _ -> ());
  let waited = ref 0.0 in
  let interval = 0.05 in
  let deadline = 1.0 in
  let alive () =
    try
      match Unix.waitpid [ Unix.WNOHANG ] handle.ssh_pid with
      | 0, _ -> true
      | _ -> false
    with _ -> false
  in
  while alive () && !waited < deadline do
    Unix.sleepf interval;
    waited := !waited +. interval
  done;
  if alive () then
    (try Unix.kill handle.ssh_pid Sys.sigterm with _ -> ());
  (try Unix.unlink handle.local_sock with _ -> ())

let run_remote ~host ?remote_socket () =
  let handle = spawn_ssh ~host ?remote_socket () in
  at_exit (fun () -> kill_ssh handle);
  let install_exit_on signal =
    try
      Sys.set_signal signal (Sys.Signal_handle (fun _ -> exit 0))
    with Invalid_argument _ -> ()
  in
  install_exit_on Sys.sigterm;
  install_exit_on Sys.sigint;
  (try Sys.set_signal Sys.sigpipe Sys.Signal_ignore
   with Invalid_argument _ -> ());
  run_proxy ~socket_path:handle.local_sock ~connect_timeout:20.0 ()
