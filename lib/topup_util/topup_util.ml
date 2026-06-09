(* Shared leaf helpers used across [topup], [topup_runtime], and [mcp].
   Depends only on the stdlib and [unix] — deliberately no compiler-libs,
   yojson, or anything else — so the back-channel-critical [topup_runtime]
   and [Blob] paths can reuse it without taking on heavier dependencies or
   coupling to the rest of the tree. *)

let rec mkdir_p ?(mode = 0o700) path =
  if path = "" || path = "/" || path = "." then ()
  else if Sys.file_exists path then ()
  else begin
    mkdir_p ~mode (Filename.dirname path);
    try Unix.mkdir path mode with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

(* Write [data] to [path] atomically: ensure the parent directory exists,
   write to [path ^ ".tmp"] (mode [perm], binary), then [Unix.rename] over
   [path]. The temp file is removed on failure. Returns the number of bytes
   written, or an error message of the form [Unix.error_message ^ ": " ^
   path]. Never raises. *)
let write_atomic ?(perm = 0o600) path (data : bytes) : (int, string) result =
  (try mkdir_p (Filename.dirname path) with _ -> ());
  let tmp = path ^ ".tmp" in
  match
    let oc =
      open_out_gen
        [ Open_wronly; Open_creat; Open_trunc; Open_binary ]
        perm tmp
    in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_bytes oc data);
    Unix.rename tmp path
  with
  | () -> Ok (Bytes.length data)
  | exception Unix.Unix_error (err, _, _) ->
      (try Sys.remove tmp with _ -> ());
      Error (Unix.error_message err ^ ": " ^ path)
  | exception Sys_error msg ->
      (* [open_out_gen] reports open failures as [Sys_error]. *)
      (try Sys.remove tmp with _ -> ());
      Error msg

(* Read the whole of regular file [path], rejecting it if larger than
   [max_bytes]. Error strings are bare so callers can prefix them. Never
   raises. *)
let read_capped ~max_bytes path : (bytes, string) result =
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

(* Expand a leading [~] or [~/] to [$HOME]. Pure string work; leaves the
   path untouched if [HOME] is unset or there is no leading tilde. *)
let expand_tilde (path : string) : string =
  if path = "~" then
    match Sys.getenv_opt "HOME" with Some h -> h | None -> path
  else if String.length path >= 2 && path.[0] = '~' && path.[1] = '/' then
    match Sys.getenv_opt "HOME" with
    | Some h -> Filename.concat h (String.sub path 2 (String.length path - 2))
    | None -> path
  else path

let iso8601_utc_now () =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

(* Resolve an environment variable expected to hold a positive integer.
   Absent, empty, unparseable, or non-positive values fall back to
   [default]. Backs the byte-size caps (TOPUP_XFER_MAX_BYTES,
   TOPUP_MAX_MESSAGE_BYTES). *)
let env_positive_int name ~default =
  match Sys.getenv_opt name with
  | None | Some "" -> default
  | Some s -> (
      match int_of_string_opt (String.trim s) with
      | Some n when n > 0 -> n
      | _ -> default)
