(* Mirror of [tools.ml]'s [xfer_max_bytes] etc. Kept here (no shared
   module) so [Blob] has zero non-stdlib dependencies and can be
   called from the back-channel reader thread without coupling to
   the rest of [Tools]. *)

let xfer_default_max_bytes = 16 * 1024 * 1024

let xfer_max_bytes () =
  match Sys.getenv_opt "TOPUP_XFER_MAX_BYTES" with
  | None | Some "" -> xfer_default_max_bytes
  | Some s -> (
      match int_of_string_opt (String.trim s) with
      | Some n when n > 0 -> n
      | _ -> xfer_default_max_bytes)

let expand_tilde (path : string) : string =
  if path = "~" then
    match Sys.getenv_opt "HOME" with Some h -> h | None -> path
  else if String.length path >= 2 && path.[0] = '~' && path.[1] = '/' then
    match Sys.getenv_opt "HOME" with
    | Some h -> Filename.concat h (String.sub path 2 (String.length path - 2))
    | None -> path
  else path

(* Lexically resolve "." and ".." in an absolute path without touching
   the filesystem. Pure string work — no [Str]. *)
let normalize_abs path =
  let parts = String.split_on_char '/' path in
  let stack =
    List.fold_left
      (fun acc seg ->
        match seg with
        | "" | "." -> acc
        | ".." -> ( match acc with _ :: tl -> tl | [] -> [])
        | s -> s :: acc)
      [] parts
  in
  "/" ^ String.concat "/" (List.rev stack)

let is_within ~root p =
  p = root || String.starts_with ~prefix:(root ^ "/") p

(* Confinement root for back-channel blob ops: a *remote* daemon reaching
   back into the local filesystem is confined here so a compromised remote
   (or untrusted code eval'd remotely via [Topup.read_back]/[write_back])
   cannot read/write arbitrary local files. [TOPUP_BACKCHANNEL_ROOT=off]
   restores the unconfined behaviour for users who trust their remotes. *)
let backchannel_confine_root () : string option =
  match Sys.getenv_opt "TOPUP_BACKCHANNEL_ROOT" with
  | Some "off" -> None
  | Some "" | None -> (
      match Sys.getenv_opt "HOME" with
      | Some h -> Some (Filename.concat h ".topup/back")
      | None -> Some "/tmp/topup-back" (* fail closed, never fail open *))
  | Some p -> Some p

(* Resolve a requested [path] to a concrete filesystem path. Unconfined
   (no [confine_root]): only expand a leading [~]. Confined: reinterpret
   the request *under* [root] (an absolute request has its leading slash
   stripped), lexically normalise, reject any [..] escape, and — when the
   parent already exists — [realpath] it to catch symlink escapes. *)
let resolve_path ?confine_root path : (string, string) result =
  match confine_root with
  | None -> Ok (expand_tilde path)
  | Some root ->
      let root = normalize_abs (if Filename.is_relative root
                                then Filename.concat (Sys.getcwd ()) root
                                else root)
      in
      let rel =
        let p = path in
        let i = ref 0 in
        while !i < String.length p && p.[!i] = '/' do incr i done;
        String.sub p !i (String.length p - !i)
      in
      let joined = normalize_abs (Filename.concat root rel) in
      if not (is_within ~root joined) then
        Error "path escapes back-channel root (TOPUP_BACKCHANNEL_ROOT)"
      else
        let parent = Filename.dirname joined in
        (match Unix.realpath parent with
         | rp when not (is_within ~root rp) ->
             Error "path escapes back-channel root via symlink"
         | _ -> Ok joined
         | exception Unix.Unix_error _ -> Ok joined (* parent not yet created *))

let rec mkdir_p path =
  if path = "" || path = "/" || path = "." then ()
  else if Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o700
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
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
  (try mkdir_p dir with _ -> ());
  let tmp = path ^ ".tmp" in
  match
    let oc =
      open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] 0o600 tmp
    in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_bytes oc bytes);
    Unix.rename tmp path
  with
  | () -> Ok (Bytes.length bytes)
  | exception Unix.Unix_error (err, _, _) ->
      (try Sys.remove tmp with _ -> ());
      Error (Unix.error_message err ^ ": " ^ path)

let get_string (args : Yojson.Safe.t) key : string option =
  match args with
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String s) -> Some s
      | _ -> None)
  | _ -> None

let text_result ?(is_error = false) text : Yojson.Safe.t =
  `Assoc
    [
      ("content", `List [ `Assoc [ ("type", `String "text"); ("text", `String text) ] ]);
      ("isError", `Bool is_error);
    ]

let json_result (j : Yojson.Safe.t) : Yojson.Safe.t =
  let s = Yojson.Safe.to_string j in
  text_result s

let dispatch ?confine_root (name : string) (args : Yojson.Safe.t) :
    Yojson.Safe.t =
  match name with
  | "_recv_blob" -> (
      match (get_string args "path", get_string args "data") with
      | None, _ -> text_result ~is_error:true "missing 'path' argument"
      | _, None -> text_result ~is_error:true "missing 'data' argument"
      | Some path, Some data -> (
          match resolve_path ?confine_root path with
          | Error msg -> text_result ~is_error:true msg
          | Ok path -> (
          match Base64.decode data with
          | Error (`Msg msg) ->
              text_result ~is_error:true ("base64 decode: " ^ msg)
          | Ok decoded ->
              let n = String.length decoded in
              let cap = xfer_max_bytes () in
              if n > cap then
                text_result ~is_error:true
                  (Printf.sprintf
                     "payload too large: %d bytes; cap is %d \
                      (TOPUP_XFER_MAX_BYTES)"
                     n cap)
              else
                match write_file_atomic ~path (Bytes.of_string decoded) with
                | Ok m ->
                    json_result
                      (`Assoc [ ("path", `String path); ("bytes", `Int m) ])
                | Error msg -> text_result ~is_error:true msg)))
  | "_send_blob" -> (
      match get_string args "path" with
      | None -> text_result ~is_error:true "missing 'path' argument"
      | Some path -> (
          match resolve_path ?confine_root path with
          | Error msg -> text_result ~is_error:true msg
          | Ok path ->
          let max_bytes = xfer_max_bytes () in
          match read_file_bytes ~max_bytes path with
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
  | other ->
      text_result ~is_error:true
        ("Blob.dispatch: refused tool name: " ^ other)
