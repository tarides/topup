val max_depth : int
val max_length : int
val max_bytes : int

(** Truncate a string to [max_bytes], appending an elision marker if cut. *)
val truncate_string : string -> string
