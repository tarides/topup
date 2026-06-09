type binding = {
  name : string;
  ty : string;
  location : Error.location option;
  preview : string option;
}

type overflow = Spill.overflow = { path : string; total_bytes : int }

type eval_result = {
  value_repr : string option;
  value_repr_overflow : overflow option;
  ty : string option;
  stdout : string;
  stdout_overflow : overflow option;
  stderr : string;
  stderr_overflow : overflow option;
  warnings : string list;
  error : Error.t option;
}

type t = {
  mutable history : string list;
  main_pid : int;
  log_path : string option;
  checkpoint_dir : string option;
  spill : Spill.t;
}

let initialized = ref false

let init_findlib () =
  try Eval_backend.init_findlib () with _ -> ()

let ensure_parent_dir path =
  try Topup_util.mkdir_p (Filename.dirname path) with _ -> ()

let starts_with_directive s =
  let n = String.length s in
  let rec skip_ws i =
    if i >= n then None
    else
      match s.[i] with
      | ' ' | '\t' | '\n' | '\r' -> skip_ws (i + 1)
      | c -> Some c
  in
  skip_ws 0 = Some '#'

let log_phrase t source =
  if starts_with_directive source then ()
  else
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

(* Prelude evaluated at session create and after every [reset]:
   makes [Topup_runtime] visible to the user under the conventional
   name [Topup]. The implementation is already statically linked
   into the binary; the .cmi search path is added by
   [Eval_backend.prepare_topup_runtime] before this runs. *)
let prelude_source = "module Topup = Topup_runtime;;"

(* Drives [Eval_backend.execute_phrase] over a literal source string
   without any of [eval]'s machinery (no capture, no spill, no
   history append, no log). Used for the session prelude where any
   failure is fatal and there is nothing user-visible to capture. *)
let exec_silent_phrase source : (unit, string) result =
  let lexbuf = Lexing.from_string source in
  Location.init lexbuf "<prelude>";
  let sink = Format.formatter_of_buffer (Buffer.create 0) in
  let prev_print = !Eval_backend.print_out_phrase in
  let err = ref None in
  Eval_backend.print_out_phrase :=
    (fun _ppf -> function
      | Outcometree.Ophr_exception (exn, _) ->
          if !err = None then err := Some (Printexc.to_string exn)
      | _ -> ());
  let finished = ref false in
  (try
     while not !finished do
       let phrase =
         try !Eval_backend.parse_toplevel_phrase lexbuf
         with End_of_file -> raise Exit
       in
       try
         let _ : bool = Eval_backend.execute_phrase true sink phrase in
         if !err <> None then raise Exit
       with
       | Exit -> raise Exit
       | exn ->
           if !err = None then err := Some (Printexc.to_string exn);
           raise Exit
     done
   with Exit -> finished := true);
  Eval_backend.print_out_phrase := prev_print;
  match !err with None -> Ok () | Some msg -> Error msg

let install_prelude () =
  Eval_backend.prepare_topup_runtime ();
  match exec_silent_phrase prelude_source with
  | Ok () -> ()
  | Error msg ->
      failwith
        ("Session prelude failed (is topup.runtime installed?): " ^ msg)

let create ?log_path ?checkpoint_dir () =
  if not !initialized then begin
    Eval_backend.initialize_toplevel_env ();
    Pretty.configure_toploop ();
    init_findlib ();
    Sys.catch_break true;
    initialized := true
  end;
  install_prelude ();
  (match checkpoint_dir with
   | None -> ()
   | Some dir -> (try Topup_util.mkdir_p dir with _ -> ()));
  {
    history = [];
    main_pid = Unix.getpid ();
    log_path;
    checkpoint_dir;
    spill = Spill.create ();
  }

let format_to_string printer x =
  let buf = Buffer.create 64 in
  let ppf = Format.formatter_of_buffer buf in
  printer ppf x;
  Format.pp_print_flush ppf ();
  Buffer.contents buf

let print_value ppf v = !Oprint.out_value ppf v
let print_type = Format_doc.compat !Oprint.out_type

let format_type_string t = Pretty.truncate_bytes (format_to_string print_type t)

let extract_outcome (p : Outcometree.out_phrase) =
  match p with
  | Ophr_eval (v, t) ->
      (Some (format_to_string print_value v), Some (format_type_string t))
  | Ophr_signature items ->
      let rec last v_acc ty_acc = function
        | [] -> (v_acc, ty_acc)
        | (Outcometree.Osig_value vd, vopt) :: rest ->
            let v_str =
              Option.map (fun v -> format_to_string print_value v) vopt
            in
            let ty_str = Some (format_type_string vd.oval_type) in
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
  let prev_print = !Eval_backend.print_out_phrase in
  Eval_backend.print_out_phrase := (fun _ppf p -> last_outcome := Some p);
  let value_repr = ref None in
  let ty = ref None in
  let error = ref None in
  let eval_complete = Atomic.make false in
  let timeout_fired = Atomic.make false in
  let watchdog secs () =
    Thread.delay secs;
    if not (Atomic.get eval_complete) then begin
      Atomic.set timeout_fired true;
      try Unix.kill t.main_pid Sys.sigint with _ -> ()
    end
  in
  let wd = Option.map (fun secs -> Thread.create (watchdog secs) ()) timeout in
  (* A [Sys.Break] reaching the eval loop means SIGINT fired — from the
     watchdog (timeout) or an external [cancel]. Record which and stop. *)
  let on_break () =
    let reason = if Atomic.get timeout_fired then "timed out" else "cancelled" in
    error := cancelled_error reason;
    raise Stop
  in
  let do_eval () =
    let lexbuf = Lexing.from_string source in
    Location.init lexbuf "<eval>";
    let sink = Format.formatter_of_buffer (Buffer.create 0) in
    try
      while true do
        let phrase =
          try !Eval_backend.parse_toplevel_phrase lexbuf
          with
          | End_of_file -> raise Stop
          | exn ->
              error := Some (Error.of_exn exn);
              raise Stop
        in
        last_outcome := None;
        (try
           let _ : bool = Eval_backend.execute_phrase true sink phrase in
           match !last_outcome with
           | Some (Ophr_exception (Sys.Break, _)) -> on_break ()
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
        | Sys.Break -> on_break ()
        | exn ->
            error := Some (Error.of_exn exn);
            raise Stop)
      done
    with Stop -> ()
  in
  let (), out, err = Capture.with_capture do_eval in
  Atomic.set eval_complete true;
  Option.iter Thread.join wd;
  Eval_backend.print_out_phrase := prev_print;
  t.history <- source :: t.history;
  if !error = None then log_phrase t source;
  let value_repr_out, value_repr_overflow =
    match !value_repr with
    | None -> (None, None)
    | Some s ->
        let s', o =
          Spill.apply t.spill ~field:"value_repr" ~limit:!Pretty.max_bytes s
        in
        (Some s', o)
  in
  let stdout_out, stdout_overflow =
    Spill.apply t.spill ~field:"stdout" ~limit:!Pretty.max_stdout_bytes out
  in
  let stderr_out, stderr_overflow =
    Spill.apply t.spill ~field:"stderr" ~limit:!Pretty.max_stderr_bytes err
  in
  {
    value_repr = value_repr_out;
    value_repr_overflow;
    ty = !ty;
    stdout = stdout_out;
    stdout_overflow;
    stderr = stderr_out;
    stderr_overflow;
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
  let env = !Eval_backend.toplevel_env in
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
  let env = !Eval_backend.toplevel_env in
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
  Eval_backend.initialize_toplevel_env ();
  t.history <- [];
  install_prelude ()

let cancel t =
  try Unix.kill t.main_pid Sys.sigint with _ -> ()

let valid_label_char c =
  match c with
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.' -> true
  | _ -> false

let validate_label label =
  if label = "" then Error "label must be non-empty"
  else if label.[0] = '.' then Error "label must not start with '.'"
  else if
    (* Reject ".." anywhere — a single dot is fine inside, e.g. "v1.2". *)
    let n = String.length label in
    let bad = ref false in
    for i = 0 to n - 2 do
      if label.[i] = '.' && label.[i + 1] = '.' then bad := true
    done;
    !bad
  then Error "label must not contain '..'"
  else
    let ok = ref true in
    String.iter (fun c -> if not (valid_label_char c) then ok := false) label;
    if !ok then Ok ()
    else Error "label may only contain [A-Za-z0-9._-]"

let read_file_opt path =
  match open_in_bin path with
  | exception Sys_error _ -> ""
  | ic ->
      let n = in_channel_length ic in
      let buf = Bytes.create n in
      really_input ic buf 0 n;
      close_in ic;
      Bytes.unsafe_to_string buf

(* Raises [Sys_error] on failure; [checkpoint]/[restore] catch it. *)
let write_file_atomic path content =
  match Topup_util.write_atomic path (Bytes.unsafe_of_string content) with
  | Ok _ -> ()
  | Error msg -> raise (Sys_error msg)

let checkpoint_path t label =
  match t.checkpoint_dir with
  | None -> None
  | Some dir -> Some (Filename.concat dir (label ^ ".ml"))

let checkpoint t ~label =
  match validate_label label with
  | Error _ as e -> e
  | Ok () -> (
      match (t.log_path, checkpoint_path t label) with
      | None, _ ->
          Error "checkpoint requires phrase logging (TOPUP_LOG is off)"
      | _, None ->
          Error "checkpoint disabled (TOPUP_CHECKPOINT_DIR=off)"
      | Some log, Some dst -> (
          try
            (match t.checkpoint_dir with
             | Some d -> (try Topup_util.mkdir_p d with _ -> ())
             | None -> ());
            let content = read_file_opt log in
            write_file_atomic dst content;
            Ok ()
          with
          | Unix.Unix_error (err, _, _) ->
              Error ("checkpoint: " ^ Unix.error_message err)
          | Sys_error msg -> Error ("checkpoint: " ^ msg)))

let restore t ~label =
  match validate_label label with
  | Error _ as e -> e
  | Ok () -> (
      match (t.log_path, checkpoint_path t label) with
      | None, _ ->
          Error "restore requires phrase logging (TOPUP_LOG is off)"
      | _, None ->
          Error "restore disabled (TOPUP_CHECKPOINT_DIR=off)"
      | Some log, Some src ->
          if not (Sys.file_exists src) then
            Error ("no such checkpoint: " ^ label)
          else (
            try
              let content = read_file_opt src in
              ensure_parent_dir log;
              write_file_atomic log content;
              reset t;
              let r = eval t (Printf.sprintf "#use %S;;" log) in
              Ok r
            with
            | Unix.Unix_error (err, _, _) ->
                Error ("restore: " ^ Unix.error_message err)
            | Sys_error msg -> Error ("restore: " ^ msg)))

let compile_to_binary t ~entry ~out ~libraries =
  Promote.compile_to_binary ~log_path:t.log_path ~entry ~out ~libraries

let list_checkpoints t =
  match t.checkpoint_dir with
  | None -> []
  | Some dir -> (
      match Sys.readdir dir with
      | exception Sys_error _ -> []
      | entries ->
          let labels =
            Array.fold_left
              (fun acc name ->
                if Filename.check_suffix name ".ml" then
                  Filename.chop_suffix name ".ml" :: acc
                else acc)
              [] entries
          in
          List.sort compare labels)
