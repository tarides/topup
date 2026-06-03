type message = Yojson.Safe.t

let read_message ic =
  match input_line ic with
  | line -> Some (Yojson.Safe.from_string line)
  | exception End_of_file -> None

let write_message oc msg =
  output_string oc (Yojson.Safe.to_string msg);
  output_char oc '\n';
  flush oc
