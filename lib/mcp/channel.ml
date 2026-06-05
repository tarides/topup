type slot = {
  mu : Mutex.t;
  cv : Condition.t;
  mutable response : Yojson.Safe.t option;
  mutable aborted : bool;
}

(* Queue entry: a request frame to dispatch.  Notifications take
   their own thread (see [reader_loop]) so cancel can interrupt an
   in-flight eval rather than serialising behind it. *)
type queue_item = Request_item of Yojson.Safe.t

type t = {
  ic : in_channel;
  oc : out_channel;
  write_mu : Mutex.t;
  pending : (int, slot) Hashtbl.t;
  pending_mu : Mutex.t;
  mutable next_id : int;
  on_request : Yojson.Safe.t -> Yojson.Safe.t;
  mutable closed : bool;
  closed_mu : Mutex.t;
  closed_cv : Condition.t;
  (* Single dispatcher thread serialises inbound work in arrival
     order; the reader thread just enqueues and keeps reading so
     back-channel responses can still be delivered while a slow
     request is in flight. *)
  work_queue : queue_item Queue.t;
  work_mu : Mutex.t;
  work_cv : Condition.t;
  mutable reader_done : bool;
}

let set_id (req : Yojson.Safe.t) id : Yojson.Safe.t =
  match req with
  | `Assoc fields ->
      let replaced = ref false in
      let fields' =
        List.map
          (fun ((k, _) as kv) ->
            if k = "id" then begin
              replaced := true;
              (k, `Int id)
            end
            else kv)
          fields
      in
      if !replaced then `Assoc fields'
      else `Assoc (("id", `Int id) :: fields')
  | other -> other

type kind =
  | Response of int
  | Request
  | Notification
  | Other

let classify (msg : Yojson.Safe.t) : kind =
  match msg with
  | `Assoc fields ->
      let has_method = List.exists (fun (k, _) -> k = "method") fields in
      let id_opt = List.assoc_opt "id" fields in
      (match (has_method, id_opt) with
       | true, Some _ -> Request
       | true, None -> Notification
       | false, Some (`Int n) -> Response n
       | _ -> Other)
  | _ -> Other

let abort_all_pending t =
  Mutex.lock t.pending_mu;
  Hashtbl.iter
    (fun _ slot ->
      Mutex.lock slot.mu;
      slot.aborted <- true;
      Condition.signal slot.cv;
      Mutex.unlock slot.mu)
    t.pending;
  Hashtbl.reset t.pending;
  Mutex.unlock t.pending_mu

let mark_closed t =
  Mutex.lock t.closed_mu;
  let was_closed = t.closed in
  t.closed <- true;
  Condition.broadcast t.closed_cv;
  Mutex.unlock t.closed_mu;
  if not was_closed then abort_all_pending t

let is_closed t =
  Mutex.lock t.closed_mu;
  let c = t.closed in
  Mutex.unlock t.closed_mu;
  c

let wait_closed t =
  Mutex.lock t.closed_mu;
  while not t.closed do Condition.wait t.closed_cv t.closed_mu done;
  Mutex.unlock t.closed_mu

let deliver_response t id msg =
  Mutex.lock t.pending_mu;
  let slot_opt = Hashtbl.find_opt t.pending id in
  Mutex.unlock t.pending_mu;
  match slot_opt with
  | None -> ()  (* late or duplicate response — drop *)
  | Some slot ->
      Mutex.lock slot.mu;
      slot.response <- Some msg;
      Condition.signal slot.cv;
      Mutex.unlock slot.mu

let error_response ~id ~code ~message : Yojson.Safe.t =
  let id_field =
    match id with Some j -> j | None -> `Null
  in
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("id", id_field);
      ( "error",
        `Assoc [ ("code", `Int code); ("message", `String message) ] );
    ]

let write_message t (msg : Yojson.Safe.t) =
  Mutex.lock t.write_mu;
  (try Rpc.write_message t.oc msg
   with _ -> mark_closed t);
  Mutex.unlock t.write_mu

let enqueue t item =
  Mutex.lock t.work_mu;
  Queue.add item t.work_queue;
  Condition.signal t.work_cv;
  Mutex.unlock t.work_mu

let process_request t msg =
  let id_field =
    match msg with
    | `Assoc fields -> List.assoc_opt "id" fields
    | _ -> None
  in
  let reply =
    match t.on_request msg with
    | r -> r
    | exception exn ->
        error_response ~id:id_field ~code:(-32603)
          ~message:("on_request raised: " ^ Printexc.to_string exn)
  in
  write_message t reply

let dispatcher_loop t =
  let rec loop () =
    Mutex.lock t.work_mu;
    while Queue.is_empty t.work_queue && not t.reader_done do
      Condition.wait t.work_cv t.work_mu
    done;
    if Queue.is_empty t.work_queue then begin
      (* reader_done set and queue drained — exit *)
      Mutex.unlock t.work_mu
    end
    else begin
      let item = Queue.pop t.work_queue in
      Mutex.unlock t.work_mu;
      (try
         match item with
         | Request_item msg -> process_request t msg
       with _ -> ());
      loop ()
    end
  in
  loop ()

let signal_reader_done t =
  Mutex.lock t.work_mu;
  t.reader_done <- true;
  Condition.broadcast t.work_cv;
  Mutex.unlock t.work_mu

let rec reader_loop t =
  match
    match Rpc.read_message t.ic with
    | exception _ -> `Eof
    | None -> `Eof
    | Some msg -> `Frame msg
  with
  | `Eof ->
      (* Peer closed its write side: no more responses to our
         outbound requests will arrive. Wake any workers blocked in
         {!request} so they error out instead of hanging — the
         dispatcher needs them to return before it can drain the
         queue and call {!mark_closed}. *)
      abort_all_pending t;
      signal_reader_done t
  | `Frame msg ->
      (try
         match classify msg with
         | Response id -> deliver_response t id msg
         | Request -> enqueue t (Request_item msg)
         | Notification ->
             (* Notifications fire-and-forget on their own thread —
                they must NOT serialise behind queued requests
                ([notifications/cancelled] has to interrupt an
                in-flight eval, not wait for it to finish). *)
             let _ : Thread.t =
               Thread.create
                 (fun () -> try ignore (t.on_request msg) with _ -> ())
                 ()
             in
             ()
         | Other -> ()
       with _ -> ());
      if not (is_closed t) then reader_loop t

let create ~ic ~oc ~on_request =
  let t =
    {
      ic;
      oc;
      write_mu = Mutex.create ();
      pending = Hashtbl.create 16;
      pending_mu = Mutex.create ();
      next_id = 1;
      on_request;
      closed = false;
      closed_mu = Mutex.create ();
      closed_cv = Condition.create ();
      work_queue = Queue.create ();
      work_mu = Mutex.create ();
      work_cv = Condition.create ();
      reader_done = false;
    }
  in
  let _ : Thread.t = Thread.create reader_loop t in
  let dispatcher =
    Thread.create
      (fun () ->
        dispatcher_loop t;
        mark_closed t)
      ()
  in
  ignore dispatcher;
  t

let request t (req : Yojson.Safe.t) : Yojson.Safe.t =
  if is_closed t then failwith "channel: closed";
  Mutex.lock t.pending_mu;
  let id = t.next_id in
  t.next_id <- id + 1;
  let slot =
    {
      mu = Mutex.create ();
      cv = Condition.create ();
      response = None;
      aborted = false;
    }
  in
  Hashtbl.add t.pending id slot;
  Mutex.unlock t.pending_mu;
  let req' = set_id req id in
  Mutex.lock t.write_mu;
  let write_ok =
    match Rpc.write_message t.oc req' with
    | () -> true
    | exception _ ->
        Mutex.unlock t.write_mu;
        mark_closed t;
        false
  in
  if write_ok then Mutex.unlock t.write_mu;
  Mutex.lock slot.mu;
  while (not slot.aborted) && slot.response = None do
    Condition.wait slot.cv slot.mu
  done;
  let response = slot.response in
  let aborted = slot.aborted in
  Mutex.unlock slot.mu;
  Mutex.lock t.pending_mu;
  Hashtbl.remove t.pending id;
  Mutex.unlock t.pending_mu;
  match (response, aborted) with
  | Some r, _ -> r
  | None, true -> failwith "channel: closed before response"
  | None, false -> failwith "channel: spurious wakeup with no response"

let notify t (msg : Yojson.Safe.t) : unit = write_message t msg

let close t =
  if not (is_closed t) then begin
    mark_closed t;
    (* Wake the dispatcher (it waits on [work_cv], not [closed_cv])
       so it observes [reader_done] and exits.  Without this the
       at_exit chain that calls [close] would hang waiting for the
       dispatcher to drain a queue that no producer is feeding. *)
    signal_reader_done t;
    (try close_in t.ic with _ -> ());
    (try close_out t.oc with _ -> ())
  end
