type result = {
  binary_path : string;
  build_log : string;
  ok : bool;
}

let marker_filename = ".topup-promote"

let valid_entry_first c =
  match c with 'a' .. 'z' | 'A' .. 'Z' | '_' -> true | _ -> false

let valid_entry_char c =
  match c with
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '\'' -> true
  | _ -> false

let validate_entry s =
  if s = "" then Error "entry must be non-empty"
  else if not (valid_entry_first s.[0]) then
    Error "entry must begin with a letter or underscore"
  else if not (String.for_all valid_entry_char s) then
    Error "entry may only contain [A-Za-z0-9_']"
  else Ok ()

(* Library names are interpolated verbatim into the generated [dune]
   S-expression; restrict them to the findlib package charset so a
   crafted name cannot inject extra dune directives or break the file. *)
let valid_lib_char c =
  match c with
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' -> true
  | _ -> false

let validate_libraries libs =
  List.fold_left
    (fun acc l ->
      match acc with
      | Error _ -> acc
      | Ok () ->
          if l = "" then Error "library name must be non-empty"
          else if not (String.for_all valid_lib_char l) then
            Error ("invalid library name " ^ l ^ " (allowed: [A-Za-z0-9._-])")
          else Ok ())
    (Ok ()) libs

let read_file path =
  match open_in_bin path with
  | exception Sys_error msg -> Error msg
  | ic ->
      let n = in_channel_length ic in
      let buf = Bytes.create n in
      really_input ic buf 0 n;
      close_in ic;
      Ok (Bytes.unsafe_to_string buf)

let dir_entries path =
  try Array.to_list (Sys.readdir path) with Sys_error _ -> []

let write_file path content =
  let oc =
    open_out_gen
      [ Open_wronly; Open_creat; Open_trunc; Open_binary ]
      0o644 path
  in
  output_string oc content;
  close_out oc

let copy_file ~src ~dst =
  let ic = open_in_bin src in
  let oc =
    open_out_gen
      [ Open_wronly; Open_creat; Open_trunc; Open_binary ]
      0o755 dst
  in
  let buf = Bytes.create 8192 in
  let rec loop () =
    match input ic buf 0 (Bytes.length buf) with
    | 0 -> ()
    | n ->
        output oc buf 0 n;
        loop ()
  in
  loop ();
  close_in ic;
  close_out oc

let drain_fd_into fd buf =
  let chunk = Bytes.create 4096 in
  let rec loop () =
    match Unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> ()
    | n ->
        Buffer.add_subbytes buf chunk 0 n;
        loop ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
  in
  loop ();
  Unix.close fd

let synthesise_dune_project ~out =
  write_file (Filename.concat out "dune-project") "(lang dune 3.6)\n"

let synthesise_dune ~out ~libraries =
  let libs_clause =
    match libraries with
    | [] -> ""
    | _ -> Printf.sprintf "\n (libraries %s)" (String.concat " " libraries)
  in
  let content = Printf.sprintf "(executable\n (name main)%s)\n" libs_clause in
  write_file (Filename.concat out "dune") content

let synthesise_main ~out ~log_contents ~entry =
  let needs_sep =
    let n = String.length log_contents in
    n > 0 && log_contents.[n - 1] <> '\n'
  in
  let sep = if needs_sep then "\n" else "" in
  let wrapper = Printf.sprintf "let () = ignore (%s ())\n" entry in
  let content = log_contents ^ sep ^ wrapper in
  write_file (Filename.concat out "main.ml") content

let run_dune ~out =
  let dev_null = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0o600 in
  let out_r, out_w = Unix.pipe ~cloexec:true () in
  let err_r, err_w = Unix.pipe ~cloexec:true () in
  let argv = [| "dune"; "build"; "--root"; out |] in
  let pid =
    try Unix.create_process "dune" argv dev_null out_w err_w
    with exn ->
      List.iter
        (fun fd -> try Unix.close fd with _ -> ())
        [ dev_null; out_r; out_w; err_r; err_w ];
      raise exn
  in
  Unix.close out_w;
  Unix.close err_w;
  let buf_out = Buffer.create 1024 in
  let buf_err = Buffer.create 1024 in
  let t_out = Thread.create (fun () -> drain_fd_into out_r buf_out) () in
  let t_err = Thread.create (fun () -> drain_fd_into err_r buf_err) () in
  let _, status = Unix.waitpid [] pid in
  Thread.join t_out;
  Thread.join t_err;
  (try Unix.close dev_null with _ -> ());
  let combined = Buffer.contents buf_out ^ Buffer.contents buf_err in
  let ok = status = Unix.WEXITED 0 in
  (combined, ok)

(* Ensure [out] is a usable output directory: create it when absent;
   when present it must be a directory that is either empty or already a
   promote target (carries the marker) — never clobber unrelated content. *)
let prepare_out_dir out : (unit, string) Stdlib.result =
  if Sys.file_exists out then
    if not (Sys.is_directory out) then
      Error ("out exists and is not a directory: " ^ out)
    else
      let entries = dir_entries out in
      if entries = [] || List.exists (fun n -> n = marker_filename) entries
      then Ok ()
      else
        Error
          ("out directory is not empty and lacks the .topup-promote marker; \
            refuse to clobber: " ^ out)
  else
    try
      (* 0o755, not the 0o700 of topup's internal state dirs: [out] is the
         operator-chosen output directory for a compiled binary, expected to
         be readable like any build artefact. *)
      Topup_util.mkdir_p ~mode:0o755 out;
      Ok ()
    with exn ->
      Error ("could not create out directory: " ^ Printexc.to_string exn)

(* Synthesise the dune project at the prepared [out], build it, and copy
   out the binary. A clean build failure is still an [Ok] result with
   [ok = false]; only I/O faults are [Error]. *)
let build_in_out ~out ~libraries ~entry ~log_contents :
    (result, string) Stdlib.result =
  try
    write_file (Filename.concat out marker_filename) "";
    synthesise_dune_project ~out;
    synthesise_dune ~out ~libraries;
    synthesise_main ~out ~log_contents ~entry;
    (* Remove the leftover binary from a prior run: dune would otherwise
       reject "Multiple rules generated for main.exe" (executable target +
       file present in source tree). *)
    (try Unix.unlink (Filename.concat out "main.exe") with _ -> ());
    let build_log, ok = run_dune ~out in
    if ok then begin
      let dst = Filename.concat out "main.exe" in
      copy_file ~src:(Filename.concat out "_build/default/main.exe") ~dst;
      Ok { binary_path = dst; build_log; ok = true }
    end
    else Ok { binary_path = ""; build_log; ok = false }
  with
  | Unix.Unix_error (err, fn, _) ->
      Error
        (Printf.sprintf "compile_to_binary: %s: %s" fn
           (Unix.error_message err))
  | Sys_error msg -> Error ("compile_to_binary: " ^ msg)

let ( let* ) = Result.bind

let compile_to_binary ~log_path ~entry ~out ~libraries =
  let* log =
    match log_path with
    | None ->
        Error "compile_to_binary requires phrase logging (TOPUP_LOG is off)"
    | Some log ->
        if Sys.file_exists log then Ok log
        else Error ("phrase log not found at " ^ log)
  in
  let* () = validate_entry entry in
  let* () = validate_libraries libraries in
  let* () =
    if Filename.is_relative out then Error "out must be an absolute path"
    else Ok ()
  in
  let* () = prepare_out_dir out in
  let* log_contents =
    Result.map_error (fun msg -> "read phrase log: " ^ msg) (read_file log)
  in
  build_in_out ~out ~libraries ~entry ~log_contents
