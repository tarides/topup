type phase = Typecheck | Runtime

type location = {
  file : string;
  line : int;
  col_start : int;
  col_end : int;
}

type t = {
  phase : phase;
  location : location option;
  message : string;
  related : string list;
}

let location_of_loc (loc : Location.t) =
  if loc.loc_ghost then None
  else
    let s = loc.loc_start in
    let e = loc.loc_end in
    let file = if s.pos_fname = "" then !Location.input_name else s.pos_fname in
    Some
      {
        file;
        line = s.pos_lnum;
        col_start = s.pos_cnum - s.pos_bol;
        col_end = e.pos_cnum - e.pos_bol;
      }

let doc_to_string (d : Format_doc.t) =
  let buf = Buffer.create 64 in
  let ppf = Format.formatter_of_buffer buf in
  Format_doc.compat Format_doc.pp_doc ppf d;
  Format.pp_print_flush ppf ();
  Buffer.contents buf

let of_report (r : Location.report) : t =
  let message = doc_to_string r.main.txt in
  let related = List.map (fun (m : Location.msg) -> doc_to_string m.txt) r.sub in
  let location = location_of_loc r.main.loc in
  { phase = Typecheck; location; message; related }

let of_runtime_exn exn : t =
  {
    phase = Runtime;
    location = None;
    message = Printexc.to_string exn;
    related = [];
  }

let of_exn exn : t =
  match Location.error_of_exn exn with
  | Some (`Ok r) -> of_report r
  | Some `Already_displayed ->
      {
        phase = Typecheck;
        location = None;
        message = "<error already displayed>";
        related = [];
      }
  | None -> of_runtime_exn exn
