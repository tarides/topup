type overflow = { path : string; total_bytes : int }

type t = {
  dir : string option;
  counter : int Atomic.t;
}

let rec rm_rf path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      let entries =
        try Sys.readdir path with Sys_error _ -> [||]
      in
      Array.iter (fun name -> rm_rf (Filename.concat path name)) entries;
      (try Unix.rmdir path with Unix.Unix_error _ -> ())
  | _ ->
      (try Unix.unlink path with Unix.Unix_error _ -> ())

(* Three-way result for each source: [`Use s] means "spill to this dir",
   [`Off] means "explicitly disabled, do not fall through", [`Unset]
   means "this source said nothing, try the next." *)
let interpret = function
  | None -> `Unset
  | Some "" | Some "off" -> `Off
  | Some path -> `Use path

let resolve_dir explicit =
  let chain = function
    | `Use _ as r -> r
    | `Off as r -> r
    | `Unset -> (
        match interpret (Sys.getenv_opt "TOPUP_SPILL_DIR") with
        | `Use _ as r -> r
        | `Off as r -> r
        | `Unset -> (
            match Sys.getenv_opt "HOME" with
            | Some home -> `Use (Filename.concat home ".topup/spill")
            | None -> `Off))
  in
  match chain (interpret explicit) with
  | `Use path -> Some path
  | `Off -> None

let create ?dir () =
  let dir =
    match resolve_dir dir with
    | None -> None
    | Some path -> (
        rm_rf path;
        try
          Topup_util.mkdir_p path;
          Some path
        with _ -> None)
  in
  { dir; counter = Atomic.make 0 }

let next_seq t = Atomic.fetch_and_add t.counter 1

let sanitise_field s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      match c with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' ->
          Buffer.add_char buf c
      | _ -> Buffer.add_char buf '_')
    s;
  Buffer.contents buf

let write_spill_file path content =
  let cap = !Pretty.max_spill_bytes in
  let len = String.length content in
  let payload, dropped =
    if len <= cap then (content, 0)
    else
      ( String.sub content 0 cap
        ^ Printf.sprintf "\n…[+%d bytes dropped]\n" (len - cap),
        len - cap )
  in
  let oc =
    open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] 0o600
      path
  in
  output_string oc payload;
  close_out oc;
  ignore dropped

let apply t ~field ~limit s =
  let len = String.length s in
  if len <= limit then (s, None)
  else begin
    let head = String.sub s 0 limit in
    let dropped = len - limit in
    match t.dir with
    | None ->
        (head ^ Printf.sprintf "…[+%d bytes]" dropped, None)
    | Some dir -> (
        let seq = next_seq t in
        let name =
          Printf.sprintf "%02d-%s.txt" seq (sanitise_field field)
        in
        let path = Filename.concat dir name in
        match write_spill_file path s with
        | () ->
            ( head
              ^ Printf.sprintf "…[+%d bytes; full at %s]" dropped path,
              Some { path; total_bytes = len } )
        | exception _ ->
            (head ^ Printf.sprintf "…[+%d bytes]" dropped, None))
  end
