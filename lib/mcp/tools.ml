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

let eval_schema =
  object_schema ~required:[ "source" ]
    [ ("source", string_prop); ("timeout", number_prop) ]

let bool_prop = `Assoc [ ("type", `String "boolean") ]

let env_schema =
  object_schema [ ("filter", string_prop); ("all", bool_prop) ]

let lookup_schema =
  object_schema ~required:[ "name" ] [ ("name", string_prop) ]

let empty_schema = object_schema []

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
         '*_overflow' field. Read that path if the full content is needed."
      ~schema:eval_schema;
    tool_def ~name:"env"
      ~description:
        "List user-defined value bindings as (name, type). Stdlib and \
         library bindings are hidden unless all:true is passed."
      ~schema:env_schema;
    tool_def ~name:"lookup"
      ~description:"Inspect a single binding by name."
      ~schema:lookup_schema;
    tool_def ~name:"reset"
      ~description:"Discard the toplevel environment and start fresh."
      ~schema:empty_schema;
    tool_def ~name:"cancel"
      ~description:"Interrupt the currently-running evaluation."
      ~schema:empty_schema;
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

let dispatch session name (args : Yojson.Safe.t) : Yojson.Safe.t =
  try
    match name with
    | "eval" -> (
        match get_string args "source" with
        | None -> text_result ~is_error:true "missing 'source' argument"
        | Some source ->
            let timeout = get_float args "timeout" in
            let r = Session.eval ?timeout session source in
            json_result (json_of_eval_result r))
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
    | _ -> text_result ~is_error:true ("unknown tool: " ^ name)
  with exn ->
    text_result ~is_error:true
      ("internal error in " ^ name ^ ": " ^ Printexc.to_string exn)
