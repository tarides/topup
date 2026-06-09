type entry = {
  name : string;
  prewarm : string option;
  pool : int;
  last_seen : string option;
  session : Local_session.t option;
}

type t = {
  entries : (string, entry) Hashtbl.t;
  persist_path : string option;
  mutex : Mutex.t;
}

let default_persist_path () =
  match Sys.getenv_opt "HOME" with
  | Some home -> Some (Filename.concat home ".topup/sessions.json")
  | None -> None

let resolve_persist_path () =
  match Sys.getenv_opt "TOPUP_SESSIONS_FILE" with
  | Some "off" | Some "" -> None
  | Some path -> Some path
  | None -> default_persist_path ()

let json_of_entry (e : entry) : Yojson.Safe.t =
  let str_or_null = function Some s -> `String s | None -> `Null in
  `Assoc
    [
      ("name", `String e.name);
      ("prewarm", str_or_null e.prewarm);
      ("pool", `Int e.pool);
      ("last_seen", str_or_null e.last_seen);
    ]

let entry_of_json (j : Yojson.Safe.t) : entry option =
  match j with
  | `Assoc fs -> (
      let get k = List.assoc_opt k fs in
      let get_string k =
        match get k with Some (`String s) -> Some s | _ -> None
      in
      let get_int k =
        match get k with
        | Some (`Int n) -> Some n
        | Some (`Float f) -> Some (int_of_float f)
        | _ -> None
      in
      match get_string "name" with
      | None -> None
      | Some name ->
          let pool = match get_int "pool" with Some n when n > 0 -> n | _ -> 1 in
          Some
            {
              name;
              prewarm = get_string "prewarm";
              pool;
              last_seen = get_string "last_seen";
              session = None;
            })
  | _ -> None

let load_from_disk path =
  match Yojson.Safe.from_file path with
  | exception _ -> []
  | `Assoc fs -> (
      match List.assoc_opt "sessions" fs with
      | Some (`List items) -> List.filter_map entry_of_json items
      | _ -> [])
  | _ -> []

let create () =
  let persist_path = resolve_persist_path () in
  let entries = Hashtbl.create 4 in
  (match persist_path with
   | Some path when Sys.file_exists path ->
       List.iter
         (fun e -> Hashtbl.replace entries e.name e)
         (load_from_disk path)
   | _ -> ());
  { entries; persist_path; mutex = Mutex.create () }

let ensure_parent_dir path =
  let dir = Filename.dirname path in
  let rec mkdir_p d =
    if d = "/" || d = "." then ()
    else if Sys.file_exists d then ()
    else (
      mkdir_p (Filename.dirname d);
      try Unix.mkdir d 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  mkdir_p dir

let snapshot_entry e =
  match e.session with
  | None -> e
  | Some s -> (
      match Local_session.last_seen s with
      | None -> e
      | Some ls -> { e with last_seen = Some ls })

let persist_locked t =
  match t.persist_path with
  | None -> ()
  | Some path ->
      let items =
        Hashtbl.fold (fun _ e acc -> snapshot_entry e :: acc) t.entries []
      in
      let items =
        List.sort (fun a b -> String.compare a.name b.name) items
      in
      let j : Yojson.Safe.t =
        `Assoc [ ("sessions", `List (List.map json_of_entry items)) ]
      in
      (try
         ensure_parent_dir path;
         let tmp = path ^ ".tmp" in
         (* 0o600: session metadata is owner-only. *)
         let oc =
           open_out_gen [ Open_wronly; Open_creat; Open_trunc ] 0o600 tmp
         in
         output_string oc (Yojson.Safe.pretty_to_string j);
         output_char oc '\n';
         close_out oc;
         Unix.rename tmp path
       with _ -> ())

let lookup t name =
  Mutex.lock t.mutex;
  let r = Hashtbl.find_opt t.entries name in
  Mutex.unlock t.mutex;
  r

let live t name =
  Mutex.lock t.mutex;
  let r =
    match Hashtbl.find_opt t.entries name with
    | Some { session = Some s; _ } -> Some s
    | _ -> None
  in
  Mutex.unlock t.mutex;
  r

let spawn_one_locked t ~name ~prewarm ~pool =
  let existing = Hashtbl.find_opt t.entries name in
  match existing with
  | Some { session = Some s; _ } when Local_session.is_live s -> s
  | _ ->
      let prewarm =
        match prewarm with
        | Some _ -> prewarm
        | None -> (
            match existing with
            | Some e -> e.prewarm
            | None -> None)
      in
      let s = Local_session.start ~name ?prewarm () in
      let entry =
        match existing with
        | Some e -> { e with prewarm; pool; session = Some s }
        | None ->
            {
              name;
              prewarm;
              pool;
              last_seen = None;
              session = Some s;
            }
      in
      Hashtbl.replace t.entries name entry;
      s

let start_session t ~name ?prewarm ?pool () =
  let pool = match pool with Some n when n > 0 -> n | _ -> 1 in
  Mutex.lock t.mutex;
  match spawn_one_locked t ~name ~prewarm ~pool with
  | exception exn ->
      Mutex.unlock t.mutex;
      raise exn
  | primary -> (
      let rec spawn_siblings i =
        if i >= pool then ()
        else
          let sib_name = Printf.sprintf "%s.%d" name i in
          match spawn_one_locked t ~name:sib_name ~prewarm ~pool:1 with
          | _ -> spawn_siblings (i + 1)
          | exception exn ->
              persist_locked t;
              Mutex.unlock t.mutex;
              raise exn
      in
      spawn_siblings 1;
      persist_locked t;
      Mutex.unlock t.mutex;
      primary)

let restart_session t ~name =
  Mutex.lock t.mutex;
  let result =
    match Hashtbl.find_opt t.entries name with
    | None ->
        Mutex.unlock t.mutex;
        failwith ("session not registered: " ^ name)
    | Some ({ session = Some s; _ } as e) -> (
        match Local_session.restart s with
        | () ->
            Hashtbl.replace t.entries name { e with session = Some s };
            persist_locked t;
            s
        | exception exn ->
            Mutex.unlock t.mutex;
            raise exn)
    | Some ({ session = None; _ } as e) -> (
        match Local_session.start ~name ?prewarm:e.prewarm () with
        | s ->
            Hashtbl.replace t.entries name { e with session = Some s };
            persist_locked t;
            s
        | exception exn ->
            Mutex.unlock t.mutex;
            raise exn)
  in
  Mutex.unlock t.mutex;
  result

let update_session t ~name ?prewarm ?pool () =
  Mutex.lock t.mutex;
  let r =
    match Hashtbl.find_opt t.entries name with
    | None -> Error ("session not registered: " ^ name)
    | Some e ->
        let merge old_v new_v =
          match new_v with Some _ -> new_v | None -> old_v
        in
        let entry =
          {
            e with
            prewarm = merge e.prewarm prewarm;
            pool = (match pool with Some n when n > 0 -> n | _ -> e.pool);
          }
        in
        Hashtbl.replace t.entries name entry;
        persist_locked t;
        Ok ()
  in
  Mutex.unlock t.mutex;
  match r with Ok () -> () | Error m -> failwith m

let iter t f =
  Mutex.lock t.mutex;
  let items =
    Hashtbl.fold (fun _ e acc -> snapshot_entry e :: acc) t.entries []
  in
  Mutex.unlock t.mutex;
  let items =
    List.sort (fun a b -> String.compare a.name b.name) items
  in
  List.iter f items

let instructions_text t =
  let has_any = Hashtbl.length t.entries > 0 in
  if not has_any then ""
  else
    let buf = Buffer.create 256 in
    Buffer.add_string buf "Known sessions:\n";
    iter t (fun e ->
        let parts = ref [] in
        let push s = parts := s :: !parts in
        (match e.session with
         | Some _ -> push "topup 0.1.0"
         | None -> push "disconnected");
        (match e.prewarm with
         | Some p when p <> "" -> push ("prewarm: " ^ p)
         | _ -> ());
        if e.pool > 1 then push (Printf.sprintf "pool: %d" e.pool);
        let live_last =
          match e.session with
          | Some s -> Local_session.last_seen s
          | None -> None
        in
        let last =
          match live_last with Some _ -> live_last | None -> e.last_seen
        in
        (match last with
         | Some ls -> push ("last: " ^ ls)
         | None -> ());
        let tags =
          List.rev !parts |> List.map (fun s -> "[" ^ s ^ "]")
        in
        Buffer.add_string buf
          (Printf.sprintf "- %s %s\n" e.name (String.concat " " tags)));
    Buffer.contents buf

let close_all t =
  Mutex.lock t.mutex;
  Hashtbl.iter
    (fun _ e ->
      match e.session with
      | Some s -> Local_session.close s
      | None -> ())
    t.entries;
  Mutex.unlock t.mutex
