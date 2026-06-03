(** Overflow records: a path to a spill file and the total byte length
    of the original (untruncated) content. *)
type overflow = { path : string; total_bytes : int }

type t

(** Resolve the spill directory and prepare it. Resolution order:
    [?dir] argument, [$TOPUP_SPILL_DIR], else [$HOME/.topup/spill]. The
    sentinel value ["off"] (in any source) disables spilling — [apply]
    will still truncate inline but writes no file and emits no path.
    If the directory cannot be created, the manager is silently
    disabled. Existing contents of the directory are removed on
    creation, so spill files do not accumulate across process
    restarts. *)
val create : ?dir:string -> unit -> t

(** [apply t ~field ~limit s]: if [String.length s <= limit], returns
    [(s, None)]. Otherwise writes the full content (capped at
    [!Pretty.max_spill_bytes] with a tail elision marker if exceeded)
    to a file named [NN-<field>.txt] under the spill directory, and
    returns a truncated inline string with an elision marker mentioning
    the spill path. If the manager is disabled or the write fails, the
    inline string is still truncated but the [overflow option] is
    [None]. *)
val apply : t -> field:string -> limit:int -> string -> string * overflow option
