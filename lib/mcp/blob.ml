(* The byte-cap, tilde-expansion, and file-I/O primitives live in
   [Topup_util] (stdlib + unix only). [Blob] is reached from the
   back-channel reader thread, so it deliberately depends on nothing
   heavier than that — sharing via [Topup_util] keeps it decoupled from
   the rest of [Tools] while removing the former copy-paste. *)

let xfer_default_max_bytes = 16 * 1024 * 1024

let xfer_max_bytes () =
  Topup_util.env_positive_int "TOPUP_XFER_MAX_BYTES"
    ~default:xfer_default_max_bytes

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
  | None -> Ok (Topup_util.expand_tilde path)
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
                match Topup_util.write_atomic path (Bytes.of_string decoded) with
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
          match Topup_util.read_capped ~max_bytes path with
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
