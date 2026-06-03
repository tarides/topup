let max_depth = ref 10
let max_steps = ref 200
let max_bytes = ref 8192
let max_stdout_bytes = ref 8192
let max_stderr_bytes = ref 8192
let max_spill_bytes = ref (10 * 1024 * 1024)

let configure_toploop () =
  Toploop.max_printer_depth := !max_depth;
  Toploop.max_printer_steps := !max_steps

let truncate_bytes ?(limit = !max_bytes) s =
  let len = String.length s in
  if len <= limit then s
  else
    let dropped = len - limit in
    String.sub s 0 limit ^ Printf.sprintf "…[+%d bytes]" dropped
