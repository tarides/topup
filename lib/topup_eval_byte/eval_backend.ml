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
  Topfind.log := ignore;
  (* topup.runtime is statically linked into the binary so that
     [Mcp.Server] can install its muxed I/O hook; mark it preloaded
     so a user-issued [#require "topup.runtime"] does not try to
     re-load the .cma. The prelude doesn't [#require]; it just
     adds the .cmi search path so [module Topup = Topup_runtime]
     typechecks. *)
  Topfind.don't_load_deeply [ "topup.runtime" ]

let prepare_topup_runtime () =
  match Findlib.package_directory "topup.runtime" with
  | dir -> Topdirs.dir_directory dir
  | exception _ -> ()
