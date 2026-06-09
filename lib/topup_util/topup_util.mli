(* Shared leaf helpers (stdlib + unix only) used across [topup],
   [topup_runtime], and [mcp]. See the .ml for why this lives in its own
   minimal-dependency library. *)

(* Recursively create [path] and any missing parents, mode [mode] (default
   [0o700]). Existing directories are left untouched. Catches [EEXIST];
   other errors propagate. *)
val mkdir_p : ?mode:int -> string -> unit

(* Atomically write [data] to [path] via a [".tmp"] sibling + [Unix.rename],
   creating the parent directory if needed (perm [perm], default [0o600]).
   Removes the temp file on failure. Returns bytes written or
   [Unix.error_message ^ ": " ^ path]. Never raises. *)
val write_atomic : ?perm:int -> string -> bytes -> (int, string) result

(* Read all of regular file [path], rejecting it when larger than
   [max_bytes]. Bare error strings (caller-prefixable). Never raises. *)
val read_capped : max_bytes:int -> string -> (bytes, string) result

(* Expand a leading [~] / [~/] against [$HOME]; identity otherwise. *)
val expand_tilde : string -> string

(* Current UTC time as [YYYY-MM-DDTHH:MM:SSZ]. *)
val iso8601_utc_now : unit -> string

(* Positive-integer environment variable with a fallback; absent/empty/
   unparseable/non-positive all yield [default]. *)
val env_positive_int : string -> default:int -> int
