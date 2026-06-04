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
    ]

let eval_batch_schema =
  object_schema ~required:[ "sources" ]
    [
      ("sources", array_string_prop);
      ("timeout", number_prop);
      ("host", host_prop);
    ]

let env_schema =
  object_schema
    [
      ("filter", string_prop); ("all", bool_prop); ("host", host_prop);
    ]

let lookup_schema =
  object_schema ~required:[ "name" ]
    [ ("name", string_prop); ("host", host_prop) ]

let load_schema =
  object_schema ~required:[ "path" ]
    [ ("path", string_prop); ("host", host_prop) ]

let host_only_schema = object_schema [ ("host", host_prop) ]

let checkpoint_schema =
  object_schema ~required:[ "label" ]
    [ ("label", string_prop); ("host", host_prop) ]

let restore_schema = checkpoint_schema

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
         brought up via start_session; omit it (or pass \"local\") for the \
         in-process session."
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
        "List user-defined value bindings as (name, type). Stdlib and \
         library bindings are hidden unless all:true is passed. Optional \
         `host` selects a remote session."
      ~schema:env_schema;
    tool_def ~name:"lookup"
      ~description:
        "Inspect a single binding by name. Optional `host` selects a \
         remote session."
      ~schema:lookup_schema;
    tool_def ~name:"reset"
      ~description:
        "Discard the toplevel environment and start fresh. Optional `host` \
         selects a remote session."
      ~schema:host_only_schema;
    tool_def ~name:"cancel"
      ~description:
        "Interrupt the currently-running evaluation. Optional `host` \
         selects a remote session; bare `cancel` cancels the local session \
         only (does NOT broadcast across hosts)."
      ~schema:host_only_schema;
    tool_def ~name:"load"
      ~description:
        "Dynlink a bytecode archive (.cma) or object file (.cmo) into the \
         live toplevel session. The driver is bytecode-only, so .cmxs is \
         not accepted; use a .cma instead. Pass an absolute path; the \
         directory of the path is added to the toplevel's load path so the \
         .cmi sitting next to the .cma is discoverable. Loaded modules \
         become available to subsequent eval calls under their compilation \
         unit names. Returns the same JSON shape as eval. Note: Toploop's \
         #load currently swallows file-not-found errors silently — confirm \
         the load worked by referencing a binding via eval. Loaded \
         archives are NOT replayed on reset and are NOT recorded in the \
         persistent phrase log; re-issue load after reset. Optional `host` \
         routes the load to a remote toplevel; the path must exist on the \
         remote filesystem."
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
  ]

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

let remove_host_field (args : Yojson.Safe.t) : Yojson.Safe.t =
  match args with
  | `Assoc fields ->
      `Assoc (List.filter (fun (k, _) -> k <> "host") fields)
  | _ -> args

let extract_host (args : Yojson.Safe.t) : string option =
  match get_string args "host" with
  | None -> None
  | Some "" | Some "local" -> None
  | Some h -> Some h

let route_remote registry host name args =
  match Host_registry.live registry host with
  | None ->
      text_result ~is_error:true
        ("host not registered: " ^ host
       ^ " (call start_session { host: " ^ host ^ " } first)")
  | Some rh -> (
      let args' = remove_host_field args in
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
      match Remote_host.send rh req with
      | exception Failure msg ->
          text_result ~is_error:true ("remote " ^ host ^ ": " ^ msg)
      | exception exn ->
          text_result ~is_error:true
            ("remote " ^ host ^ ": " ^ Printexc.to_string exn)
      | response -> (
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
                      text_result ~is_error:true ("remote " ^ host ^ ": " ^ msg)
                  | _ -> text_result ~is_error:true "remote: malformed response"))
          | _ -> text_result ~is_error:true "remote: malformed response"))

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

let dispatch session registry name (args : Yojson.Safe.t) : Yojson.Safe.t =
  try
    match name with
    | "start_session" | "restart_session" | "update_host" ->
        dispatch_lifecycle registry name args
    | _ -> (
        match extract_host args with
        | None -> dispatch_local session name args
        | Some host -> route_remote registry host name args)
  with exn ->
    text_result ~is_error:true
      ("internal error in " ^ name ^ ": " ^ Printexc.to_string exn)
