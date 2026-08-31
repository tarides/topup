type message = Yojson.Safe.t

let default_max_message_bytes = 64 * 1024 * 1024

(* Upper bound on a single newline-delimited frame. Must exceed the
   largest legitimate frame — a [TOPUP_XFER_MAX_BYTES] blob (16 MiB
   default) base64-encodes to ~21.8 MiB plus JSON envelope — hence the
   64 MiB default. Guards the reader against a peer that streams an
   unbounded line to exhaust memory. *)
let max_message_bytes () =
  match Sys.getenv_opt "TOPUP_MAX_MESSAGE_BYTES" with
  | None | Some "" -> default_max_message_bytes
  | Some s -> (
      match int_of_string_opt (String.trim s) with
      | Some n when n > 0 -> n
      | _ -> default_max_message_bytes)

exception Message_too_large of int

(* Read one newline-terminated line from [ic] into a growable buffer,
   capped at [max] bytes. Returns [None] at EOF with nothing buffered.
   Raises [Message_too_large] rather than allocating past the cap — the
   caller (the [Channel] reader) treats any read exception as EOF and
   tears the connection down. *)
let read_line_bounded ic ~max =
  let buf = Buffer.create 256 in
  let rec loop () =
    match input_char ic with
    | '\n' -> Some (Buffer.contents buf)
    | c ->
        if Buffer.length buf >= max then raise (Message_too_large max);
        Buffer.add_char buf c;
        loop ()
    | exception End_of_file ->
        if Buffer.length buf = 0 then None else Some (Buffer.contents buf)
  in
  loop ()

let read_message ic =
  match read_line_bounded ic ~max:(max_message_bytes ()) with
  | None -> None
  | Some line -> Some (Yojson.Safe.from_string line)

exception Timeout

(* Read one newline-terminated frame directly from [fd] under a
   wall-clock [deadline] (absolute [Unix.gettimeofday] seconds), using
   [Unix.select] for readiness rather than [SO_RCVTIMEO]. The latter
   does not reliably interrupt a blocking buffered read on every
   platform — notably macOS/arm64, where relying on it wedged the
   [initialize] handshake until the CI job timed out.

   Reads a byte at a time and stops exactly at ['\n'], so it consumes
   nothing past the frame and a buffered [in_channel] wrapping the same
   [fd] can be used for the rest of the session without losing bytes.
   Raises {!Timeout} if the deadline passes before a full frame arrives,
   {!Message_too_large} past the cap, and returns [None] on EOF. *)
let read_message_deadline fd ~deadline =
  let max = max_message_bytes () in
  let buf = Buffer.create 256 in
  let byte = Bytes.create 1 in
  let rec loop () =
    let remaining = deadline -. Unix.gettimeofday () in
    if remaining <= 0.0 then raise Timeout;
    match Unix.select [ fd ] [] [] remaining with
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
    | [], _, _ -> raise Timeout
    | _ -> (
        match Unix.read fd byte 0 1 with
        | exception
            Unix.Unix_error ((Unix.EINTR | Unix.EAGAIN | Unix.EWOULDBLOCK), _, _)
          ->
            loop ()
        | 0 -> if Buffer.length buf = 0 then None else Some (Buffer.contents buf)
        | _ -> (
            match Bytes.get byte 0 with
            | '\n' -> Some (Buffer.contents buf)
            | c ->
                if Buffer.length buf >= max then raise (Message_too_large max);
                Buffer.add_char buf c;
                loop ()))
  in
  match loop () with
  | None -> None
  | Some line -> Some (Yojson.Safe.from_string line)

let write_message oc msg =
  output_string oc (Yojson.Safe.to_string msg);
  output_char oc '\n';
  flush oc
