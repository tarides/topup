type io_hook = {
  read : string -> bytes;
  write : string -> bytes -> unit;
}

let xfer_default_max_bytes = 16 * 1024 * 1024

let xfer_max_bytes () =
  Topup_util.env_positive_int "TOPUP_XFER_MAX_BYTES"
    ~default:xfer_default_max_bytes

let read_file path =
  match Topup_util.read_capped ~max_bytes:(xfer_max_bytes ()) path with
  | Ok b -> b
  | Error msg -> failwith ("Topup.read_back: " ^ msg)

let write_file_atomic path bytes =
  let cap = xfer_max_bytes () in
  let n = Bytes.length bytes in
  if n > cap then
    failwith
      (Printf.sprintf
         "Topup.write_back: payload too large: %d bytes; cap is %d \
          (TOPUP_XFER_MAX_BYTES)"
         n cap)
  else
    match Topup_util.write_atomic path bytes with
    | Ok _ -> ()
    | Error msg -> failwith ("Topup.write_back: " ^ msg)

let direct_hook = { read = read_file; write = write_file_atomic }
let current_hook = ref direct_hook
let install_hook h = current_hook := h
let read_back path = !current_hook.read path
let write_back path bytes = !current_hook.write path bytes
