(** Capture stdout and stderr emitted while [f] runs. *)
val with_capture : (unit -> 'a) -> 'a * string * string
