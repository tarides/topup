let initialize_toplevel_env = Toploop.initialize_toplevel_env
let toplevel_env = Toploop.toplevel_env
let parse_toplevel_phrase = Toploop.parse_toplevel_phrase
let print_out_phrase = Toploop.print_out_phrase
let execute_phrase = Toploop.execute_phrase
let max_printer_depth = Toploop.max_printer_depth
let max_printer_steps = Toploop.max_printer_steps

let init_findlib () =
  Findlib.init ();
  Topfind.add_predicates [ "byte"; "toploop" ];
  Topfind.log := ignore
