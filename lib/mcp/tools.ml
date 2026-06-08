open Topup

let tool_def ~name ~description ~schema : Yojson.Safe.t =
  `Assoc
    [
      ("name", `String name);
      ("description", `String description);
      ("inputSchema", schema);
    ]

let object_schema ?(required = []) properties : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ("properties", `Assoc properties);
      ("required", `List (List.map (fun s -> `String s) required));
    ]

let string_prop = `Assoc [ ("type", `String "string") ]
let number_prop = `Assoc [ ("type", `String "number") ]
let bool_prop = `Assoc [ ("type", `String "boolean") ]
let host_prop = string_prop
let session_prop = string_prop

let array_string_prop : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "array");
      ("items", `Assoc [ ("type", `String "string") ]);
    ]

let eval_schema =
  object_schema ~required:[ "source" ]
    [
      ("source", string_prop);
      ("timeout", number_prop);
      ("host", host_prop);
      ("session", session_prop);
    ]

let eval_batch_schema =
  object_schema ~required:[ "sources" ]
    [
      ("sources", array_string_prop);
      ("timeout", number_prop);
      ("host", host_prop);
      ("session", session_prop);
    ]

let env_schema =
  object_schema
    [
      ("filter", string_prop);
      ("all", bool_prop);
      ("host", host_prop);
      ("session", session_prop);
    ]

let lookup_schema =
  object_schema ~required:[ "name" ]
    [
      ("name", string_prop);
      ("host", host_prop);
      ("session", session_prop);
    ]

let load_schema =
  object_schema ~required:[ "path" ]
    [
      ("path", string_prop);
      ("host", host_prop);
      ("session", session_prop);
    ]

let host_or_session_schema =
  object_schema [ ("host", host_prop); ("session", session_prop) ]

let checkpoint_schema =
  object_schema ~required:[ "label" ]
    [
      ("label", string_prop);
      ("host", host_prop);
      ("session", session_prop);
    ]

let restore_schema = checkpoint_schema

let compile_to_binary_schema =
  object_schema ~required:[ "entry"; "out" ]
    [
      ("entry", string_prop);
      ("out", string_prop);
      ("libraries", array_string_prop);
      ("host", host_prop);
      ("session", session_prop);
    ]

let push_file_schema =
  object_schema ~required:[ "host"; "local_path" ]
    [
      ("host", host_prop);
      ("local_path", string_prop);
      ("remote_path", string_prop);
    ]

let pull_file_schema =
  object_schema ~required:[ "host"; "remote_path" ]
    [
      ("host", host_prop);
      ("remote_path", string_prop);
      ("local_path", string_prop);
    ]

let start_session_schema =
  object_schema ~required:[ "host" ]
    [ ("host", host_prop); ("remote_socket", string_prop) ]

let restart_session_schema =
  object_schema ~required:[ "host" ] [ ("host", host_prop) ]

let update_host_schema =
  object_schema ~required:[ "host" ]
    [
      ("host", host_prop);
      ("description", string_prop);
      ("os", string_prop);
    ]

let start_local_session_schema =
  object_schema ~required:[ "session" ]
    [
      ("session", session_prop);
      ("prewarm", string_prop);
      ("pool", number_prop);
    ]

let restart_local_session_schema =
  object_schema ~required:[ "session" ] [ ("session", session_prop) ]

let update_local_session_schema =
  object_schema ~required:[ "session" ]
    [
      ("session", session_prop);
      ("prewarm", string_prop);
      ("pool", number_prop);
    ]

let descriptors : Yojson.Safe.t list =
  [
    tool_def ~name:"eval"
      ~description:
        "Evaluate one or more OCaml phrases in the persistent toplevel \
         session. eval returns as soon as the top-level expression returns; \
         background activity (Lwt/Eio fibres, Thread.create, Domain.spawn) \
         is the caller's responsibility — it keeps running, is NOT killed \
         by reset, and its later writes to stdout/stderr may land in a \
         subsequent eval's capture or on the server's real stdout. If you \
         need a fibre's result, join/await it before the top-level \
         expression returns. Oversized value_repr/stdout/stderr are \
         truncated inline with a '…[+N bytes; full at <path>]' marker; the \
         full content is written to the path advertised in the matching \
         '*_overflow' field. Read that path if the full content is needed. \
         Optional `host` routes the call to a remote toplevel previously \
         brought up via start_session; optional `session` routes to a \
         named local subprocess brought up via start_local_session. \
         Pass at most one — they are mutually exclusive. Omit both \
         (or pass \"local\") for the in-process session."
      ~schema:eval_schema;
    tool_def ~name:"eval_batch"
      ~description:
        "Evaluate a list of OCaml source strings sequentially in the \
         persistent toplevel. Each element is treated like a separate \
         `eval` call — bindings from earlier elements are visible to \
         later ones. Stops on the first element whose `error` is \
         non-null; the returned `results` array contains every element \
         evaluated, in order, ending with the failing one. \
         `stopped_on_error` is `true` iff a failure stopped the batch \
         short of `sources.length`. `timeout` is per element, not per \
         batch. Use `eval_batch` to amortise protocol overhead for \
         tight inner loops, especially when `host:` routes to a remote \
         daemon. Returns the same eval_result shape as `eval` for \
         every element; overflow/spill semantics are unchanged."
      ~schema:eval_batch_schema;
    tool_def ~name:"env"
      ~description:
        "List user-defined value bindings as (name, type). Use to recall \
         the workspace built up across previous eval calls — bindings \
         persist, you don't have to. Stdlib and library bindings are \
         hidden unless `all: true`. Optional `host`/`session` selects a \
         routed session."
      ~schema:env_schema;
    tool_def ~name:"lookup"
      ~description:
        "Inspect a single binding by name: returns type, source location, \
         and a small value preview. Pair with `env` to navigate a session \
         you didn't build yourself or have lost track of. Optional \
         `host`/`session` selects a routed session."
      ~schema:lookup_schema;
    tool_def ~name:"reset"
      ~description:
        "Discard the toplevel environment and start fresh. For branching \
         exploration or recovery from a corrupted state, prefer \
         `restore { label }` instead — it gives you back a known-good \
         workspace rather than an empty one. Reset also drops `#load`-ed \
         libraries; re-issue `load` after. Optional `host`/`session` \
         selects a routed session."
      ~schema:host_or_session_schema;
    tool_def ~name:"cancel"
      ~description:
        "Interrupt the currently-running evaluation (sends SIGINT to the \
         eval thread, surfaces as `evaluation timed out` in the eval \
         result). Optional `host`/`session` selects a routed session; \
         bare `cancel` cancels the local in-process eval only (does NOT \
         broadcast across hosts)."
      ~schema:host_or_session_schema;
    tool_def ~name:"load"
      ~description:
        "Dynlink a compiled archive into the live toplevel session. \
         Accepted extensions follow the driver: .cma / .cmo under topup, \
         .cmxs under topup-opt. Pass an absolute path; the directory of \
         the path is added to the toplevel's load path so the .cmi sitting \
         next to the archive is discoverable. Loaded modules become \
         available to subsequent eval calls under their compilation unit \
         names. Returns the same JSON shape as eval. Loaded archives are \
         NOT replayed on reset and are NOT recorded in the persistent \
         phrase log; re-issue load after reset. Optional `host` routes \
         the load to a remote toplevel; the path must exist on the remote \
         filesystem (and the remote driver determines which extensions \
         are accepted)."
      ~schema:load_schema;
    tool_def ~name:"checkpoint"
      ~description:
        "Snapshot the current phrase log under `label`. The snapshot is \
         plain OCaml source written to \
         $TOPUP_CHECKPOINT_DIR/<label>.ml (default \
         ~/.topup/checkpoints/). Overwrites any prior snapshot with the \
         same label, atomically (write to .tmp then rename). Requires \
         phrase logging to be enabled (TOPUP_LOG unset or pointing at a \
         writable file). Label must match [A-Za-z0-9._-]+ and must not \
         start with a dot or contain `..`. Pair with `restore` to branch \
         exploration or recover from a corrupted toplevel. Optional \
         `host` routes the call to a remote session previously brought \
         up via start_session; the snapshot then lives under the remote \
         user's home, not locally."
      ~schema:checkpoint_schema;
    tool_def ~name:"restore"
      ~description:
        "Reset the toplevel environment and replay the checkpoint named \
         `label`. The current phrase log is replaced with the \
         checkpoint's contents before replay so it stays consistent with \
         the live session. Returns the same JSON shape as `eval`, \
         reflecting the result of #use-ing the restored log: a non-null \
         `error` means a phrase failed mid-replay and the session is in \
         an intermediate state. Note: #load-ed libraries are NOT in the \
         phrase log; re-issue `load` after restoring a checkpoint that \
         depended on them. Optional `host` selects a remote session; \
         checkpoints are per-host (the remote daemon's own checkpoint \
         dir is what gets restored)."
      ~schema:restore_schema;
    tool_def ~name:"compile_to_binary"
      ~description:
        "Promote the current session into a standalone native binary. \
         The phrase log is dumped verbatim into a synthesised dune \
         project under `out`, built with `dune build`, and the \
         resulting executable is copied to `out/main.exe`. v1 takes \
         the whole successful-phrase log — curate by `restore`-ing a \
         clean checkpoint first if the log carries exploratory \
         clutter. `entry` is the name of a binding currently in scope \
         with type `unit -> _`; the synthesised wrapper is `let () = \
         ignore (<entry> ())`. `libraries` is an optional list of \
         findlib package names (e.g. [\"yojson\", \"re\"]); each is \
         emitted as a `(libraries ...)` entry in the synthesised \
         dune file. `out` must be an absolute path: created on \
         demand, refused if non-empty without a prior \
         `.topup-promote` marker (so re-runs in the same directory \
         work). Returns `{ ok, binary_path, build_log }` — `ok=false` \
         with the dune output in `build_log` means inputs were \
         valid but the build failed. Known limitations: \
         `#load`-ed `.cma`/`.cmxs` archives are not auto-linked, and \
         `#require`-d packages not listed in `libraries` will fail \
         to resolve. Requires phrase logging to be enabled (TOPUP_LOG \
         unset or pointing at a writable file) and `dune` on PATH. \
         Optional `host` routes the call to a remote session; the \
         binary then lands on the remote filesystem under the remote \
         `out` path. Optional `session` routes to a named local \
         subprocess."
      ~schema:compile_to_binary_schema;
    tool_def ~name:"push_file"
      ~description:
        "Copy a file from the local MCP-server filesystem to the \
         remote daemon registered as `host`. `host` is required; \
         purely-local copies are rejected. `local_path` is read on \
         the side running the MCP server. `remote_path` defaults to \
         $TOPUP_XFER_DIR/<basename of local_path> on the remote \
         (default $HOME/.topup/xfer/, settable via TOPUP_XFER_DIR; \
         =off requires `remote_path` to be passed explicitly). \
         Returns { remote_path, bytes }. Payload travels base64 in \
         the MCP request, so files are size-capped at \
         TOPUP_XFER_MAX_BYTES bytes (default 16 MiB) — oversized \
         files are rejected before any bytes are read. The remote \
         write is atomic (.tmp + rename) so a crash mid-transfer \
         cannot leave a partial file at `remote_path`. Pair with \
         subsequent eval calls that `open_in remote_path` to feed \
         a remote OCaml session local data without rsync."
      ~schema:push_file_schema;
    tool_def ~name:"pull_file"
      ~description:
        "Copy a file from the remote daemon registered as `host` \
         back to the local MCP-server filesystem. `host` is \
         required. `local_path` defaults to $TOPUP_XFER_DIR/<basename \
         of remote_path> on the local side (default \
         $HOME/.topup/xfer/, settable via TOPUP_XFER_DIR; =off \
         requires `local_path` to be passed explicitly). Returns \
         { local_path, bytes }. Size cap matches `push_file` \
         (TOPUP_XFER_MAX_BYTES, default 16 MiB); the remote \
         daemon refuses to send oversized files before any bytes \
         leave the disk. Local write is atomic. Pair with prior \
         eval calls that wrote artefacts on the remote (open_out / \
         flush) to bring final results back without rsync."
      ~schema:pull_file_schema;
    tool_def ~name:"start_session"
      ~description:
        "Bring up a remote topup session on `host`. Opens an SSH tunnel \
         (`ssh -L <local>:<remote> <host> topup --socket <remote>`) and \
         performs the initial MCP `initialize` handshake. Idempotent: a \
         second call against a live tunnel is a no-op. The remote socket \
         path defaults to ~/.topup/sockets/topup.sock on the remote host \
         and may be pinned with `remote_socket`. Returns the registered \
         host name and the remote socket path on success, or a structured \
         error with phase=\"connect\" on failure."
      ~schema:start_session_schema;
    tool_def ~name:"restart_session"
      ~description:
        "Kill the existing tunnel for `host` and bring it up again. Use \
         when the tunnel is wedged or the remote daemon has crashed; for a \
         fresh-OCaml-environment restart, use `reset` instead."
      ~schema:restart_session_schema;
    tool_def ~name:"update_host"
      ~description:
        "Set or replace the `description` and/or `os` metadata for an \
         already-registered host. The metadata is surfaced in the \
         `instructions` block at the next `initialize` handshake. Pass \
         only the fields you want to change; omitted fields are left \
         untouched."
      ~schema:update_host_schema;
    tool_def ~name:"start_local_session"
      ~description:
        "Bring up a named local topup session as a subprocess and \
         optionally pre-warm it. Forks `topup --socket <path>` and \
         performs the MCP `initialize` handshake. If `prewarm` is \
         given, evaluates `#use <prewarm>;;` in the subprocess before \
         returning — a failing prewarm kills the subprocess and \
         surfaces the error. When `pool` > 1, also spawns siblings \
         named `<session>.1` … `<session>.(pool-1)` sharing the same \
         prewarm; replicas exist so `restore` against a sibling \
         branches off the primary without paying cold-load cost. \
         Idempotent: a second call against a live session is a no-op."
      ~schema:start_local_session_schema;
    tool_def ~name:"restart_local_session"
      ~description:
        "Kill the existing subprocess for `session` and bring it up \
         again with the same prewarm. Use when the subprocess is \
         wedged or has crashed; for a fresh-OCaml-environment restart \
         within the same subprocess, use `reset` instead."
      ~schema:restart_local_session_schema;
    tool_def ~name:"update_local_session"
      ~description:
        "Set or replace the `prewarm` path and/or `pool` size for an \
         already-registered named session. The metadata is persisted \
         to ~/.topup/sessions.json and surfaced in the next \
         `initialize` handshake. Does NOT affect the running \
         subprocess — call `restart_local_session` for changes to \
         take effect on the live session."
      ~schema:update_local_session_schema;
  ]

let xfer_default_max_bytes = 16 * 1024 * 1024

let xfer_max_bytes () =
  match Sys.getenv_opt "TOPUP_XFER_MAX_BYTES" with
  | None | Some "" -> xfer_default_max_bytes
  | Some s -> (
      match int_of_string_opt (String.trim s) with
      | Some n when n > 0 -> n
      | _ -> xfer_default_max_bytes)

(* Resolve TOPUP_XFER_DIR:
   - Some path     : directory to use as the default destination.
   - None          : disabled — caller must pass an explicit path.
   The =off literal disables; absent variable falls back to
   $HOME/.topup/xfer/. *)
let xfer_dir () : string option =
  match Sys.getenv_opt "TOPUP_XFER_DIR" with
  | Some "off" -> None
  | Some s when s <> "" -> Some s
  | _ -> (
      match Sys.getenv_opt "HOME" with
      | Some home when home <> "" ->
          Some (Filename.concat home ".topup/xfer")
      | _ -> Some "/tmp/topup-xfer")

let expand_tilde (path : string) : string =
  if path = "~" then
    match Sys.getenv_opt "HOME" with Some h -> h | None -> path
  else if String.length path >= 2
       && path.[0] = '~'
       && path.[1] = '/'
  then
    match Sys.getenv_opt "HOME" with
    | Some h -> Filename.concat h (String.sub path 2 (String.length path - 2))
    | None -> path
  else path

let rec mkdir_p path =
  if path = "" || path = "/" || path = "." then ()
  else if Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let read_file_bytes ~max_bytes path : (bytes, string) result =
  match Unix.stat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
      Error ("no such file: " ^ path)
  | exception Unix.Unix_error (err, _, _) ->
      Error (Unix.error_message err ^ ": " ^ path)
  | st ->
      if st.Unix.st_kind <> Unix.S_REG then
        Error ("not a regular file: " ^ path)
      else if st.Unix.st_size > max_bytes then
        Error
          (Printf.sprintf
             "file too large: %s is %d bytes; cap is %d (TOPUP_XFER_MAX_BYTES)"
             path st.Unix.st_size max_bytes)
      else begin
        let ic = open_in_bin path in
        Fun.protect
          ~finally:(fun () -> close_in_noerr ic)
          (fun () ->
            let n = st.Unix.st_size in
            let b = Bytes.create n in
            really_input ic b 0 n;
            Ok b)
      end

let write_file_atomic ~path bytes : (int, string) result =
  let dir = Filename.dirname path in
  (try mkdir_p dir
   with exn ->
     ignore exn);
  let tmp = path ^ ".tmp" in
  match
    let oc = open_out_bin tmp in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_bytes oc bytes);
    Unix.rename tmp path
  with
  | () -> Ok (Bytes.length bytes)
  | exception Unix.Unix_error (err, _, _) ->
      (try Sys.remove tmp with _ -> ());
      Error (Unix.error_message err ^ ": " ^ path)
  | exception Sys_error msg ->
      (try Sys.remove tmp with _ -> ());
      Error msg

let json_of_phase = function
  | Error.Typecheck -> `String "typecheck"
  | Error.Runtime -> `String "runtime"

let json_of_location (loc : Error.location) : Yojson.Safe.t =
  `Assoc
    [
      ("file", `String loc.file);
      ("line", `Int loc.line);
      ("col_start", `Int loc.col_start);
      ("col_end", `Int loc.col_end);
    ]

let json_of_error (e : Error.t) : Yojson.Safe.t =
  `Assoc
    [
      ("phase", json_of_phase e.phase);
      ( "location",
        match e.location with
        | Some l -> json_of_location l
        | None -> `Null );
      ("message", `String e.message);
      ("related", `List (List.map (fun s -> `String s) e.related));
    ]

let string_opt = function Some s -> `String s | None -> `Null

let json_of_overflow (o : Session.overflow) : Yojson.Safe.t =
  `Assoc
    [ ("path", `String o.path); ("total_bytes", `Int o.total_bytes) ]

let overflow_opt = function
  | Some o -> json_of_overflow o
  | None -> `Null

let json_of_eval_result (r : Session.eval_result) : Yojson.Safe.t =
  `Assoc
    [
      ("value_repr", string_opt r.value_repr);
      ("value_repr_overflow", overflow_opt r.value_repr_overflow);
      ("type", string_opt r.ty);
      ("stdout", `String r.stdout);
      ("stdout_overflow", overflow_opt r.stdout_overflow);
      ("stderr", `String r.stderr);
      ("stderr_overflow", overflow_opt r.stderr_overflow);
      ("warnings", `List (List.map (fun s -> `String s) r.warnings));
      ( "error",
        match r.error with Some e -> json_of_error e | None -> `Null );
    ]

let json_of_compile_result (r : Promote.result) : Yojson.Safe.t =
  `Assoc
    [
      ("ok", `Bool r.ok);
      ( "binary_path",
        if r.binary_path = "" then `Null else `String r.binary_path );
      ("build_log", `String r.build_log);
    ]

let json_of_binding (b : Session.binding) : Yojson.Safe.t =
  `Assoc
    [
      ("name", `String b.name);
      ("type", `String b.ty);
      ( "location",
        match b.location with
        | Some l -> json_of_location l
        | None -> `Null );
      ("preview", string_opt b.preview);
    ]

let text_result ?(is_error = false) text : Yojson.Safe.t =
  `Assoc
    [
      ( "content",
        `List [ `Assoc [ ("type", `String "text"); ("text", `String text) ] ]
      );
      ("isError", `Bool is_error);
    ]

let json_result j = text_result (Yojson.Safe.to_string j)

let get_field (args : Yojson.Safe.t) key =
  match args with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let get_string args key =
  match get_field args key with Some (`String s) -> Some s | _ -> None

let get_float args key =
  match get_field args key with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | _ -> None

let get_bool args key =
  match get_field args key with Some (`Bool b) -> Some b | _ -> None

let get_string_list args key =
  match get_field args key with
  | Some (`List items) -> (
      try
        Some
          (List.map (function `String s -> s | _ -> raise Exit) items)
      with Exit -> None)
  | _ -> None

let remove_routing_fields (args : Yojson.Safe.t) : Yojson.Safe.t =
  match args with
  | `Assoc fields ->
      `Assoc
        (List.filter (fun (k, _) -> k <> "host" && k <> "session") fields)
  | _ -> args

let extract_host (args : Yojson.Safe.t) : string option =
  match get_string args "host" with
  | None -> None
  | Some "" | Some "local" -> None
  | Some h -> Some h

let extract_session (args : Yojson.Safe.t) : string option =
  match get_string args "session" with
  | None -> None
  | Some "" | Some "local" -> None
  | Some s -> Some s

let unwrap_routed_response ~label response =
  match response with
  | `Assoc fields -> (
      match List.assoc_opt "result" fields with
      | Some r -> r
      | None -> (
          match List.assoc_opt "error" fields with
          | Some (`Assoc err_fields) ->
              let msg =
                match List.assoc_opt "message" err_fields with
                | Some (`String s) -> s
                | _ -> "unknown error"
              in
              text_result ~is_error:true (label ^ ": " ^ msg)
          | _ -> text_result ~is_error:true (label ^ ": malformed response")))
  | _ -> text_result ~is_error:true (label ^ ": malformed response")

(* Parse the inner `{content:[{text:...}], isError:?}` envelope produced
   by `text_result`/`json_result` on the remote side. JSON-bodied tool
   results round-trip through a stringified text field; success means
   parseable JSON, [isError=true] surfaces the text verbatim. *)
let parse_text_content_json (resp : Yojson.Safe.t) : (Yojson.Safe.t, string) result =
  let is_error =
    match resp with
    | `Assoc fs -> (
        match List.assoc_opt "isError" fs with
        | Some (`Bool b) -> b
        | _ -> false)
    | _ -> false
  in
  let text =
    match resp with
    | `Assoc fs -> (
        match List.assoc_opt "content" fs with
        | Some (`List (`Assoc cf :: _)) -> (
            match List.assoc_opt "text" cf with
            | Some (`String s) -> Some s
            | _ -> None)
        | _ -> None)
    | _ -> None
  in
  match text with
  | None -> Error "malformed response"
  | Some s ->
      if is_error then Error s
      else
        try Ok (Yojson.Safe.from_string s)
        with Yojson.Json_error _ -> Error s

let int_field json key =
  match json with
  | `Assoc fs -> (
      match List.assoc_opt key fs with
      | Some (`Int n) -> Some n
      | Some (`Float f) -> Some (int_of_float f)
      | _ -> None)
  | _ -> None

let string_field json key =
  match json with
  | `Assoc fs -> (
      match List.assoc_opt key fs with
      | Some (`String s) -> Some s
      | _ -> None)
  | _ -> None

let route_remote registry host name args =
  match Host_registry.live registry host with
  | None ->
      text_result ~is_error:true
        ("host not registered: " ^ host
       ^ " (call start_session { host: " ^ host ^ " } first)")
  | Some rh -> (
      let args' = remove_routing_fields args in
      let req : Yojson.Safe.t =
        `Assoc
          [
            ("jsonrpc", `String "2.0");
            ("id", `Int 0);
            ("method", `String "tools/call");
            ( "params",
              `Assoc
                [ ("name", `String name); ("arguments", args') ] );
          ]
      in
      let label = "remote " ^ host in
      match Remote_host.send rh req with
      | exception Failure msg -> text_result ~is_error:true (label ^ ": " ^ msg)
      | exception exn ->
          text_result ~is_error:true (label ^ ": " ^ Printexc.to_string exn)
      | response -> unwrap_routed_response ~label response)

let route_local_session pool session name args =
  match Session_pool.live pool session with
  | None ->
      text_result ~is_error:true
        ("session not registered: " ^ session
       ^ " (call start_local_session { session: " ^ session ^ " } first)")
  | Some ls -> (
      let args' = remove_routing_fields args in
      let req : Yojson.Safe.t =
        `Assoc
          [
            ("jsonrpc", `String "2.0");
            ("id", `Int 0);
            ("method", `String "tools/call");
            ( "params",
              `Assoc
                [ ("name", `String name); ("arguments", args') ] );
          ]
      in
      let label = "session " ^ session in
      match Local_session.send ls req with
      | exception Failure msg -> text_result ~is_error:true (label ^ ": " ^ msg)
      | exception exn ->
          text_result ~is_error:true (label ^ ": " ^ Printexc.to_string exn)
      | response -> unwrap_routed_response ~label response)

let connect_error_result host msg =
  let payload : Yojson.Safe.t =
    `Assoc
      [
        ( "error",
          `Assoc
            [
              ("phase", `String "connect");
              ("host", `String host);
              ("message", `String msg);
            ] );
      ]
  in
  let r = json_result payload in
  match r with
  | `Assoc fs -> `Assoc (("isError", `Bool true) :: List.remove_assoc "isError" fs)
  | _ -> r

let dispatch_local session name (args : Yojson.Safe.t) : Yojson.Safe.t =
  match name with
  | "eval" -> (
      match get_string args "source" with
      | None -> text_result ~is_error:true "missing 'source' argument"
      | Some source ->
          let timeout = get_float args "timeout" in
          let r = Session.eval ?timeout session source in
          json_result (json_of_eval_result r))
  | "eval_batch" -> (
      match get_string_list args "sources" with
      | None ->
          text_result ~is_error:true
            "'sources' must be an array of strings"
      | Some [] ->
          text_result ~is_error:true "'sources' must be non-empty"
      | Some srcs ->
          let timeout = get_float args "timeout" in
          let rec loop acc = function
            | [] -> (List.rev acc, false)
            | s :: rest ->
                let r = Session.eval ?timeout session s in
                let acc' = r :: acc in
                if r.error <> None && rest <> [] then
                  (List.rev acc', true)
                else if rest = [] then (List.rev acc', false)
                else loop acc' rest
          in
          let results, stopped = loop [] srcs in
          let payload : Yojson.Safe.t =
            `Assoc
              [
                ( "results",
                  `List (List.map json_of_eval_result results) );
                ("stopped_on_error", `Bool stopped);
              ]
          in
          json_result payload)
  | "env" ->
      let filter = get_string args "filter" in
      let all = get_bool args "all" in
      let bs = Session.env ?filter ?all session in
      json_result (`List (List.map json_of_binding bs))
  | "lookup" -> (
      match get_string args "name" with
      | None -> text_result ~is_error:true "missing 'name' argument"
      | Some n ->
          let r =
            match Session.lookup session n with
            | None -> `Null
            | Some b -> json_of_binding b
          in
          json_result r)
  | "reset" ->
      Session.reset session;
      text_result "ok"
  | "cancel" ->
      Session.cancel session;
      text_result "ok"
  | "load" -> (
      match get_string args "path" with
      | None -> text_result ~is_error:true "missing 'path' argument"
      | Some path ->
          let accepted, suggested, backend_name =
            match Sys.backend_type with
            | Sys.Native -> ([ ".cmxs" ], ".cmxs", "Native")
            | Sys.Bytecode -> ([ ".cma"; ".cmo" ], ".cma", "Bytecode")
            | Sys.Other s -> ([], s, "Other " ^ s)
          in
          let ext = String.lowercase_ascii (Filename.extension path) in
          if not (List.mem ext accepted) then
            text_result ~is_error:true
              (Printf.sprintf
                 "load: %s has extension %s; this driver accepts %s (got \
                  Sys.backend_type = %s)"
                 path
                 (if ext = "" then "(none)" else ext)
                 suggested backend_name)
          else if not (Sys.file_exists path) then
            text_result ~is_error:true
              (Printf.sprintf "load: file not found: %s" path)
          else
            let dir = Filename.dirname path in
            let phrase =
              Printf.sprintf "#directory %S;;\n#load %S;;" dir path
            in
            let r = Session.eval session phrase in
            json_result (json_of_eval_result r))
  | "checkpoint" -> (
      match get_string args "label" with
      | None -> text_result ~is_error:true "missing 'label' argument"
      | Some label -> (
          match Session.checkpoint session ~label with
          | Ok () ->
              json_result
                (`Assoc [ ("ok", `Bool true); ("label", `String label) ])
          | Error msg -> text_result ~is_error:true msg))
  | "restore" -> (
      match get_string args "label" with
      | None -> text_result ~is_error:true "missing 'label' argument"
      | Some label -> (
          match Session.restore session ~label with
          | Ok r -> json_result (json_of_eval_result r)
          | Error msg -> text_result ~is_error:true msg))
  | "compile_to_binary" -> (
      match (get_string args "entry", get_string args "out") with
      | None, _ -> text_result ~is_error:true "missing 'entry' argument"
      | _, None -> text_result ~is_error:true "missing 'out' argument"
      | Some entry, Some out ->
          let libraries =
            Option.value (get_string_list args "libraries") ~default:[]
          in
          match
            Session.compile_to_binary session ~entry ~out ~libraries
          with
          | Ok r -> json_result (json_of_compile_result r)
          | Error msg -> text_result ~is_error:true msg)
  | "_recv_blob" -> (
      match (get_string args "path", get_string args "data") with
      | None, _ -> text_result ~is_error:true "missing 'path' argument"
      | _, None -> text_result ~is_error:true "missing 'data' argument"
      | Some path, Some data ->
          let path = expand_tilde path in
          (match Base64.decode data with
           | Error (`Msg msg) ->
               text_result ~is_error:true ("base64 decode: " ^ msg)
           | Ok decoded ->
               let bytes_in = String.length decoded in
               let cap = xfer_max_bytes () in
               if bytes_in > cap then
                 text_result ~is_error:true
                   (Printf.sprintf
                      "payload too large: %d bytes; cap is %d \
                       (TOPUP_XFER_MAX_BYTES)"
                      bytes_in cap)
               else
                 match
                   write_file_atomic ~path (Bytes.of_string decoded)
                 with
                 | Ok n ->
                     json_result
                       (`Assoc
                          [ ("path", `String path); ("bytes", `Int n) ])
                 | Error msg -> text_result ~is_error:true msg))
  | "_send_blob" -> (
      match get_string args "path" with
      | None -> text_result ~is_error:true "missing 'path' argument"
      | Some path ->
          let path = expand_tilde path in
          let max_bytes = xfer_max_bytes () in
          (match read_file_bytes ~max_bytes path with
           | Error msg -> text_result ~is_error:true msg
           | Ok b ->
               let encoded = Base64.encode_string (Bytes.to_string b) in
               json_result
                 (`Assoc
                    [
                      ("path", `String path);
                      ("data", `String encoded);
                      ("bytes", `Int (Bytes.length b));
                    ])))
  | _ -> text_result ~is_error:true ("unknown tool: " ^ name)

let dispatch_lifecycle registry name (args : Yojson.Safe.t) : Yojson.Safe.t =
  match name with
  | "start_session" -> (
      match get_string args "host" with
      | None -> text_result ~is_error:true "missing 'host' argument"
      | Some "" | Some "local" ->
          text_result ~is_error:true
            "host 'local' is the in-process session; start_session is for remotes"
      | Some host -> (
          let remote_socket = get_string args "remote_socket" in
          match Host_registry.start_session registry ~host ?remote_socket () with
          | rh ->
              let payload : Yojson.Safe.t =
                `Assoc
                  [
                    ("ok", `Bool true);
                    ("host", `String host);
                    ("remote_socket", `String (Remote_host.remote_socket rh));
                  ]
              in
              json_result payload
          | exception Failure msg -> connect_error_result host msg
          | exception exn ->
              connect_error_result host (Printexc.to_string exn)))
  | "restart_session" -> (
      match get_string args "host" with
      | None -> text_result ~is_error:true "missing 'host' argument"
      | Some "" | Some "local" ->
          text_result ~is_error:true
            "host 'local' is the in-process session; restart_session is for remotes"
      | Some host -> (
          match Host_registry.restart_session registry ~host with
          | rh ->
              let payload : Yojson.Safe.t =
                `Assoc
                  [
                    ("ok", `Bool true);
                    ("host", `String host);
                    ("remote_socket", `String (Remote_host.remote_socket rh));
                  ]
              in
              json_result payload
          | exception Failure msg -> connect_error_result host msg
          | exception exn ->
              connect_error_result host (Printexc.to_string exn)))
  | "update_host" -> (
      match get_string args "host" with
      | None -> text_result ~is_error:true "missing 'host' argument"
      | Some "" | Some "local" ->
          text_result ~is_error:true
            "host 'local' has no mutable metadata"
      | Some host -> (
          let description = get_string args "description" in
          let os = get_string args "os" in
          match Host_registry.update_host registry ~host ?description ?os () with
          | () -> text_result "ok"
          | exception Failure msg -> text_result ~is_error:true msg))
  | _ -> text_result ~is_error:true ("unknown tool: " ^ name)

let connect_error_session_result session msg =
  let payload : Yojson.Safe.t =
    `Assoc
      [
        ( "error",
          `Assoc
            [
              ("phase", `String "connect");
              ("session", `String session);
              ("message", `String msg);
            ] );
      ]
  in
  let r = json_result payload in
  match r with
  | `Assoc fs -> `Assoc (("isError", `Bool true) :: List.remove_assoc "isError" fs)
  | _ -> r

let get_int args key =
  match get_field args key with
  | Some (`Int n) -> Some n
  | Some (`Float f) -> Some (int_of_float f)
  | _ -> None

let dispatch_pool_lifecycle pool name (args : Yojson.Safe.t) : Yojson.Safe.t =
  match name with
  | "start_local_session" -> (
      match get_string args "session" with
      | None -> text_result ~is_error:true "missing 'session' argument"
      | Some "" | Some "local" ->
          text_result ~is_error:true
            "session 'local' is the in-process session; \
             start_local_session is for named subprocesses"
      | Some session -> (
          let prewarm = get_string args "prewarm" in
          let pool_size = get_int args "pool" in
          match
            Session_pool.start_session pool ~name:session ?prewarm
              ?pool:pool_size ()
          with
          | ls ->
              let payload : Yojson.Safe.t =
                `Assoc
                  [
                    ("ok", `Bool true);
                    ("session", `String session);
                    ("local_socket", `String (Local_session.local_socket ls));
                    ( "pool",
                      `Int (match pool_size with Some n -> n | None -> 1) );
                  ]
              in
              json_result payload
          | exception Failure msg -> connect_error_session_result session msg
          | exception exn ->
              connect_error_session_result session (Printexc.to_string exn)))
  | "restart_local_session" -> (
      match get_string args "session" with
      | None -> text_result ~is_error:true "missing 'session' argument"
      | Some "" | Some "local" ->
          text_result ~is_error:true
            "session 'local' is the in-process session; \
             restart_local_session is for named subprocesses"
      | Some session -> (
          match Session_pool.restart_session pool ~name:session with
          | ls ->
              let payload : Yojson.Safe.t =
                `Assoc
                  [
                    ("ok", `Bool true);
                    ("session", `String session);
                    ("local_socket", `String (Local_session.local_socket ls));
                  ]
              in
              json_result payload
          | exception Failure msg -> connect_error_session_result session msg
          | exception exn ->
              connect_error_session_result session (Printexc.to_string exn)))
  | "update_local_session" -> (
      match get_string args "session" with
      | None -> text_result ~is_error:true "missing 'session' argument"
      | Some "" | Some "local" ->
          text_result ~is_error:true
            "session 'local' has no mutable metadata"
      | Some session -> (
          let prewarm = get_string args "prewarm" in
          let pool_size = get_int args "pool" in
          match
            Session_pool.update_session pool ~name:session ?prewarm
              ?pool:pool_size ()
          with
          | () -> text_result "ok"
          | exception Failure msg -> text_result ~is_error:true msg))
  | _ -> text_result ~is_error:true ("unknown tool: " ^ name)

let send_internal_tool rh ~name ~(args : Yojson.Safe.t) : Yojson.Safe.t =
  let req : Yojson.Safe.t =
    `Assoc
      [
        ("jsonrpc", `String "2.0");
        ("id", `Int 0);
        ("method", `String "tools/call");
        ( "params",
          `Assoc
            [ ("name", `String name); ("arguments", args) ] );
      ]
  in
  Remote_host.send rh req

let ( let* ) = Result.bind

let default_xfer_path ~basename : (string, string) result =
  match xfer_dir () with
  | Some dir -> Ok (Filename.concat dir basename)
  | None ->
      Error
        "no default path: TOPUP_XFER_DIR=off, the corresponding path \
         argument must be supplied"

let routed_send_internal rh ~label ~name ~(args : Yojson.Safe.t) :
    (Yojson.Safe.t, string) result =
  match send_internal_tool rh ~name ~args with
  | exception Failure msg -> Error (label ^ ": " ^ msg)
  | exception exn -> Error (label ^ ": " ^ Printexc.to_string exn)
  | response -> (
      let inner = unwrap_routed_response ~label response in
      match parse_text_content_json inner with
      | Ok j -> Ok j
      | Error msg -> Error (label ^ ": " ^ msg))

let do_push_file rh ~label ~args =
  let* local_path =
    Result.map_error
      (fun () -> "missing 'local_path' argument")
      (Option.to_result ~none:() (get_string args "local_path"))
  in
  let local_path = expand_tilde local_path in
  let* remote_path =
    match get_string args "remote_path" with
    | Some p -> Ok (expand_tilde p)
    | None -> default_xfer_path ~basename:(Filename.basename local_path)
  in
  let max_bytes = xfer_max_bytes () in
  let* b = read_file_bytes ~max_bytes local_path in
  let data = Base64.encode_string (Bytes.to_string b) in
  let blob_args : Yojson.Safe.t =
    `Assoc [ ("path", `String remote_path); ("data", `String data) ]
  in
  let* j = routed_send_internal rh ~label ~name:"_recv_blob" ~args:blob_args in
  let bytes = Option.value (int_field j "bytes") ~default:(Bytes.length b) in
  let final_path = Option.value (string_field j "path") ~default:remote_path in
  Ok
    (`Assoc [ ("remote_path", `String final_path); ("bytes", `Int bytes) ]
      : Yojson.Safe.t)

let do_pull_file rh ~label ~args =
  let* remote_path =
    Result.map_error
      (fun () -> "missing 'remote_path' argument")
      (Option.to_result ~none:() (get_string args "remote_path"))
  in
  let remote_path = expand_tilde remote_path in
  let* local_path =
    match get_string args "local_path" with
    | Some p -> Ok (expand_tilde p)
    | None -> default_xfer_path ~basename:(Filename.basename remote_path)
  in
  let blob_args : Yojson.Safe.t = `Assoc [ ("path", `String remote_path) ] in
  let* j = routed_send_internal rh ~label ~name:"_send_blob" ~args:blob_args in
  let* data =
    Option.to_result
      ~none:(label ^ ": remote response missing 'data'")
      (string_field j "data")
  in
  let* decoded =
    match Base64.decode data with
    | Ok s -> Ok s
    | Error (`Msg msg) -> Error (label ^ ": base64 decode: " ^ msg)
  in
  let cap = xfer_max_bytes () in
  let n = String.length decoded in
  let* () =
    if n > cap then
      Error
        (Printf.sprintf
           "payload too large: %d bytes; cap is %d (TOPUP_XFER_MAX_BYTES)" n
           cap)
    else Ok ()
  in
  let* m = write_file_atomic ~path:local_path (Bytes.of_string decoded) in
  Ok
    (`Assoc [ ("local_path", `String local_path); ("bytes", `Int m) ]
      : Yojson.Safe.t)

let dispatch_xfer registry name (args : Yojson.Safe.t) : Yojson.Safe.t =
  let session_set =
    match extract_session args with Some _ -> true | None -> false
  in
  if session_set then
    text_result ~is_error:true
      "host and session are mutually exclusive; push_file/pull_file require \
       host (the boundary is local↔remote)"
  else
    let host =
      match get_string args "host" with
      | None | Some "" | Some "local" -> None
      | Some h -> Some h
    in
    match host with
    | None ->
        text_result ~is_error:true
          (name
         ^ ": 'host' is required (push_file/pull_file cross the local↔remote \
            boundary; same-machine copies don't go through topup)")
    | Some h -> (
        match Host_registry.live registry h with
        | None ->
            text_result ~is_error:true
              ("host not registered: " ^ h ^ " (call start_session { host: "
             ^ h ^ " } first)")
        | Some rh ->
            let label = "remote " ^ h in
            let result =
              match name with
              | "push_file" -> do_push_file rh ~label ~args
              | "pull_file" -> do_pull_file rh ~label ~args
              | _ -> Error ("unknown xfer tool: " ^ name)
            in
            (match result with
             | Ok j -> json_result j
             | Error msg -> text_result ~is_error:true msg))

let dispatch session registry pool name (args : Yojson.Safe.t) : Yojson.Safe.t =
  try
    match name with
    | "start_session" | "restart_session" | "update_host" ->
        dispatch_lifecycle registry name args
    | "start_local_session" | "restart_local_session" | "update_local_session"
      ->
        dispatch_pool_lifecycle pool name args
    | "push_file" | "pull_file" -> dispatch_xfer registry name args
    | _ -> (
        match (extract_host args, extract_session args) with
        | Some _, Some _ ->
            text_result ~is_error:true
              "host and session are mutually exclusive; pass at most one"
        | None, None -> dispatch_local session name args
        | None, Some s -> route_local_session pool s name args
        | Some h, None -> route_remote registry h name args)
  with exn ->
    text_result ~is_error:true
      ("internal error in " ^ name ^ ": " ^ Printexc.to_string exn)
