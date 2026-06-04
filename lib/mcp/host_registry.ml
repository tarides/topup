type entry = {
  name : string;
  description : string option;
  os : string option;
  remote_socket : string;
  last_seen : string option;
  host : Remote_host.t option;
}

type t = {
  entries : (string, entry) Hashtbl.t;
  persist_path : string option;
  mutex : Mutex.t;
}

let default_persist_path () =
  match Sys.getenv_opt "HOME" with
  | Some home -> Some (Filename.concat home ".topup/hosts.json")
  | None -> None

let resolve_persist_path () =
  match Sys.getenv_opt "TOPUP_HOSTS_FILE" with
  | Some "off" | Some "" -> None
  | Some path -> Some path
  | None -> default_persist_path ()

let json_of_entry (e : entry) : Yojson.Safe.t =
  let str_or_null = function Some s -> `String s | None -> `Null in
  `Assoc
    [
      ("name", `String e.name);
      ("description", str_or_null e.description);
      ("os", str_or_null e.os);
      ("remote_socket", `String e.remote_socket);
      ("last_seen", str_or_null e.last_seen);
    ]

let entry_of_json (j : Yojson.Safe.t) : entry option =
  match j with
  | `Assoc fs -> (
      let get k = List.assoc_opt k fs in
      let get_string k =
        match get k with Some (`String s) -> Some s | _ -> None
      in
      match get_string "name" with
      | None -> None
      | Some name ->
          let remote_socket =
            match get_string "remote_socket" with
            | Some s -> s
            | None -> ""
          in
          Some
            {
              name;
              description = get_string "description";
              os = get_string "os";
              remote_socket;
              last_seen = get_string "last_seen";
              host = None;
            })
  | _ -> None

let load_from_disk path =
  match Yojson.Safe.from_file path with
  | exception _ -> []
  | `Assoc fs -> (
      match List.assoc_opt "hosts" fs with
      | Some (`List items) ->
          List.filter_map entry_of_json items
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
      (try Unix.mkdir d 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()))
  in
  mkdir_p dir

let snapshot_entry e =
  match e.host with
  | None -> e
  | Some h -> (
      match Remote_host.last_seen h with
      | None -> e
      | Some ls -> { e with last_seen = Some ls })

let persist_locked t =
  match t.persist_path with
  | None -> ()
  | Some path ->
      let items =
        Hashtbl.fold
          (fun _ e acc -> snapshot_entry e :: acc)
          t.entries []
      in
      let items =
        List.sort (fun a b -> String.compare a.name b.name) items
      in
      let j : Yojson.Safe.t =
        `Assoc [ ("hosts", `List (List.map json_of_entry items)) ]
      in
      (try
         ensure_parent_dir path;
         let tmp = path ^ ".tmp" in
         let oc = open_out tmp in
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
    | Some { host = Some h; _ } -> Some h
    | _ -> None
  in
  Mutex.unlock t.mutex;
  r

let start_session t ~host ?remote_socket () =
  Mutex.lock t.mutex;
  let existing = Hashtbl.find_opt t.entries host in
  (match existing with
   | Some { host = Some h; _ } when Remote_host.is_live h ->
       Mutex.unlock t.mutex;
       h
   | _ -> (
       let remote_socket =
         match remote_socket with
         | Some p -> Some p
         | None -> (
             match existing with
             | Some e when e.remote_socket <> "" -> Some e.remote_socket
             | _ -> None)
       in
       match Remote_host.start ~host ?remote_socket () with
       | h ->
           let entry =
             match existing with
             | Some e ->
                 {
                   e with
                   remote_socket = Remote_host.remote_socket h;
                   host = Some h;
                 }
             | None ->
                 {
                   name = host;
                   description = None;
                   os = None;
                   remote_socket = Remote_host.remote_socket h;
                   last_seen = None;
                   host = Some h;
                 }
           in
           Hashtbl.replace t.entries host entry;
           persist_locked t;
           Mutex.unlock t.mutex;
           h
       | exception exn ->
           Mutex.unlock t.mutex;
           raise exn))

let restart_session t ~host =
  Mutex.lock t.mutex;
  let result =
    match Hashtbl.find_opt t.entries host with
    | None ->
        Mutex.unlock t.mutex;
        failwith ("host not registered: " ^ host)
    | Some ({ host = Some h; _ } as e) -> (
        match Remote_host.restart h with
        | () ->
            Hashtbl.replace t.entries host { e with host = Some h };
            persist_locked t;
            h
        | exception exn ->
            Mutex.unlock t.mutex;
            raise exn)
    | Some ({ host = None; _ } as e) -> (
        let remote_socket =
          if e.remote_socket = "" then None else Some e.remote_socket
        in
        match Remote_host.start ~host ?remote_socket () with
        | h ->
            Hashtbl.replace t.entries host
              { e with host = Some h; remote_socket = Remote_host.remote_socket h };
            persist_locked t;
            h
        | exception exn ->
            Mutex.unlock t.mutex;
            raise exn)
  in
  Mutex.unlock t.mutex;
  result

let update_host t ~host ?description ?os () =
  Mutex.lock t.mutex;
  let r =
    match Hashtbl.find_opt t.entries host with
    | None -> Error ("host not registered: " ^ host)
    | Some e ->
        let merge old_v new_v =
          match new_v with Some _ -> new_v | None -> old_v
        in
        let entry =
          {
            e with
            description = merge e.description description;
            os = merge e.os os;
          }
        in
        Hashtbl.replace t.entries host entry;
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
  let buf = Buffer.create 512 in
  Buffer.add_string buf
    "Persistent OCaml toplevel. Bindings survive across eval calls.\n\n";
  Buffer.add_string buf
    "Pass an optional `host` to route eval/env/lookup/load/reset/cancel to \
     a remote toplevel.\nCall start_session first to bring the host up.\n\n";
  Buffer.add_string buf "This topup-mcp is version 0.1.0.\n\n";
  Buffer.add_string buf "Known hosts:\n";
  Buffer.add_string buf "- local [in-process]\n";
  iter t (fun e ->
      let parts = ref [] in
      let push s = parts := s :: !parts in
      (match e.host with
       | Some _ -> push "topup 0.1.0"
       | None -> push "disconnected");
      (match e.description with
       | Some d when d <> "" -> push d
       | _ -> ());
      (match e.os with
       | Some s when s <> "" -> push s
       | _ -> ());
      let live_last =
        match e.host with
        | Some h -> Remote_host.last_seen h
        | None -> None
      in
      let last = match live_last with Some _ -> live_last | None -> e.last_seen in
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
      match e.host with Some h -> Remote_host.close h | None -> ())
    t.entries;
  Mutex.unlock t.mutex
