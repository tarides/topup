type binding = {
  name : string;
  ty : string;
  location : Error.location option;
  preview : string option;
}

type eval_result = {
  value_repr : string option;
  ty : string option;
  stdout : string;
  stderr : string;
  warnings : string list;
  error : Error.t option;
}

type t = {
  mutable history : string list;
  main_pid : int;
  log_path : string option;
}

let initialized = ref false

let init_findlib () =
  try
    Findlib.init ();
    Topfind.add_predicates [ "byte"; "toploop" ];
    Topfind.log := ignore
  with _ -> ()

let ensure_parent_dir path =
  let dir = Filename.dirname path in
  if dir = "" || dir = "." || dir = "/" then ()
  else
    try Unix.mkdir dir 0o700 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    | _ -> ()

let log_phrase t source =
  match t.log_path with
  | None -> ()
  | Some path -> (
      try
        ensure_parent_dir path;
        let oc =
          open_out_gen [ Open_append; Open_creat; Open_text ] 0o600 path
        in
        output_string oc source;
        let n = String.length source in
        if n = 0 || source.[n - 1] <> '\n' then output_char oc '\n';
        close_out oc
      with _ -> ())

let create ?log_path () =
  if not !initialized then begin
    Toploop.initialize_toplevel_env ();
    Pretty.configure_toploop ();
    init_findlib ();
    Sys.catch_break true;
    initialized := true
  end;
  { history = []; main_pid = Unix.getpid (); log_path }

let format_to_string printer x =
  let buf = Buffer.create 64 in
  let ppf = Format.formatter_of_buffer buf in
  printer ppf x;
  Format.pp_print_flush ppf ();
  Pretty.truncate_bytes (Buffer.contents buf)

let print_value ppf v = !Oprint.out_value ppf v
let print_type = Format_doc.compat !Oprint.out_type

let extract_outcome (p : Outcometree.out_phrase) =
  match p with
  | Ophr_eval (v, t) ->
      (Some (format_to_string print_value v), Some (format_to_string print_type t))
  | Ophr_signature items ->
      let rec last v_acc ty_acc = function
        | [] -> (v_acc, ty_acc)
        | (Outcometree.Osig_value vd, vopt) :: rest ->
            let v_str =
              Option.map (fun v -> format_to_string print_value v) vopt
            in
            let ty_str = Some (format_to_string print_type vd.oval_type) in
            last
              (match v_str with Some _ -> v_str | None -> v_acc)
              ty_str rest
        | _ :: rest -> last v_acc ty_acc rest
      in
      last None None items
  | Ophr_exception _ -> (None, None)

exception Stop

let cancelled_error reason =
  Some
    {
      Error.phase = Runtime;
      location = None;
      message = "evaluation " ^ reason;
      related = [];
    }

let eval ?timeout t source =
  let last_outcome = ref None in
  let prev_print = !Toploop.print_out_phrase in
  Toploop.print_out_phrase := (fun _ppf p -> last_outcome := Some p);
  let value_repr = ref None in
  let ty = ref None in
  let error = ref None in
  let done_flag = Atomic.make false in
  let timeout_fired = Atomic.make false in
  let watchdog secs () =
    Thread.delay secs;
    if not (Atomic.get done_flag) then begin
      Atomic.set timeout_fired true;
      try Unix.kill t.main_pid Sys.sigint with _ -> ()
    end
  in
  let wd = Option.map (fun secs -> Thread.create (watchdog secs) ()) timeout in
  let do_eval () =
    let lexbuf = Lexing.from_string source in
    Location.init lexbuf "<eval>";
    let sink = Format.formatter_of_buffer (Buffer.create 0) in
    try
      while true do
        let phrase =
          try !Toploop.parse_toplevel_phrase lexbuf
          with End_of_file -> raise Stop
        in
        last_outcome := None;
        (try
           let _ : bool = Toploop.execute_phrase true sink phrase in
           match !last_outcome with
           | Some (Ophr_exception (Sys.Break, _)) ->
               let reason =
                 if Atomic.get timeout_fired then "timed out"
                 else "cancelled"
               in
               error := cancelled_error reason;
               raise Stop
           | Some (Ophr_exception (exn, _)) ->
               error := Some (Error.of_runtime_exn exn);
               raise Stop
           | Some outcome ->
               let v, ty' = extract_outcome outcome in
               if v <> None then value_repr := v;
               if ty' <> None then ty := ty'
           | None -> ()
         with
        | Stop -> raise Stop
        | Sys.Break ->
            let reason =
              if Atomic.get timeout_fired then "timed out" else "cancelled"
            in
            error := cancelled_error reason;
            raise Stop
        | exn ->
            error := Some (Error.of_exn exn);
            raise Stop)
      done
    with Stop -> ()
  in
  let (), out, err = Capture.with_capture do_eval in
  Atomic.set done_flag true;
  Option.iter Thread.join wd;
  Toploop.print_out_phrase := prev_print;
  t.history <- source :: t.history;
  if !error = None then log_phrase t source;
  {
    value_repr = !value_repr;
    ty = !ty;
    stdout = out;
    stderr = err;
    warnings = [];
    error = !error;
  }

let format_type_expr (ty : Types.type_expr) =
  let buf = Buffer.create 64 in
  let ppf = Format.formatter_of_buffer buf in
  Printtyp.type_scheme ppf ty;
  Format.pp_print_flush ppf ();
  Pretty.truncate_bytes (Buffer.contents buf)

let is_user_origin t (file : string) =
  file = "<eval>"
  || match t.log_path with Some p -> file = p | None -> false

let env ?filter ?(all = false) t : binding list =
  let env = !Toploop.toplevel_env in
  let bindings =
    Env.fold_values
      (fun name _path (vd : Types.value_description) acc ->
        {
          name;
          ty = format_type_expr vd.val_type;
          location = Error.location_of_loc vd.val_loc;
          preview = None;
        }
        :: acc)
      None env []
  in
  let bindings =
    if all then bindings
    else
      List.filter
        (fun b ->
          match b.location with
          | Some l -> is_user_origin t l.file
          | None -> false)
        bindings
  in
  match filter with
  | None -> bindings
  | Some prefix ->
      List.filter (fun b -> String.starts_with ~prefix b.name) bindings

let lookup _t name : binding option =
  let env = !Toploop.toplevel_env in
  match Env.find_value_by_name (Longident.Lident name) env with
  | exception Not_found -> None
  | _path, vd ->
      Some
        {
          name;
          ty = format_type_expr vd.val_type;
          location = Error.location_of_loc vd.val_loc;
          preview = None;
        }

let reset t =
  Toploop.initialize_toplevel_env ();
  t.history <- []

let cancel t =
  try Unix.kill t.main_pid Sys.sigint with _ -> ()
