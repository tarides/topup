type io_hook = {
  read : string -> bytes;
  write : string -> bytes -> unit;
}

let xfer_default_max_bytes = 16 * 1024 * 1024

let xfer_max_bytes () =
  match Sys.getenv_opt "TOPUP_XFER_MAX_BYTES" with
  | None | Some "" -> xfer_default_max_bytes
  | Some s -> (
      match int_of_string_opt (String.trim s) with
      | Some n when n > 0 -> n
      | _ -> xfer_default_max_bytes)

let rec mkdir_p path =
  if path = "" || path = "/" || path = "." then ()
  else if Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o700
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let read_file path =
  match Unix.stat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
      failwith ("Topup.read_back: no such file: " ^ path)
  | exception Unix.Unix_error (err, _, _) ->
      failwith
        ("Topup.read_back: " ^ Unix.error_message err ^ ": " ^ path)
  | st ->
      if st.Unix.st_kind <> Unix.S_REG then
        failwith ("Topup.read_back: not a regular file: " ^ path)
      else
        let cap = xfer_max_bytes () in
        if st.Unix.st_size > cap then
          failwith
            (Printf.sprintf
               "Topup.read_back: file too large: %s is %d bytes; cap is %d \
                (TOPUP_XFER_MAX_BYTES)"
               path st.Unix.st_size cap)
        else begin
          let ic = open_in_bin path in
          Fun.protect
            ~finally:(fun () -> close_in_noerr ic)
            (fun () ->
              let n = st.Unix.st_size in
              let b = Bytes.create n in
              really_input ic b 0 n;
              b)
        end

let write_file_atomic path bytes =
  let cap = xfer_max_bytes () in
  let n = Bytes.length bytes in
  if n > cap then
    failwith
      (Printf.sprintf
         "Topup.write_back: payload too large: %d bytes; cap is %d \
          (TOPUP_XFER_MAX_BYTES)"
         n cap)
  else begin
    let dir = Filename.dirname path in
    (try mkdir_p dir with _ -> ());
    let tmp = path ^ ".tmp" in
    match
      let oc = open_out_bin tmp in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () -> output_bytes oc bytes);
      Unix.rename tmp path
    with
    | () -> ()
    | exception Unix.Unix_error (err, _, _) ->
        (try Sys.remove tmp with _ -> ());
        failwith
          ("Topup.write_back: " ^ Unix.error_message err ^ ": " ^ path)
  end

let direct_hook = { read = read_file; write = write_file_atomic }
let current_hook = ref direct_hook
let install_hook h = current_hook := h
let read_back path = !current_hook.read path
let write_back path bytes = !current_hook.write path bytes
