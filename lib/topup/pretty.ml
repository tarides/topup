let max_depth = 5
let max_length = 100
let max_bytes = 8192

let truncate_string s =
  if String.length s <= max_bytes then s
  else String.sub s 0 max_bytes ^ "…[truncated]"
