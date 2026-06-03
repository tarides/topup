let drain fd buf =
  let chunk = Bytes.create 4096 in
  let rec loop () =
    match Unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> ()
    | n ->
        Buffer.add_subbytes buf chunk 0 n;
        loop ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
  in
  loop ();
  Unix.close fd

let with_capture f =
  Format.pp_print_flush Format.std_formatter ();
  Format.pp_print_flush Format.err_formatter ();
  flush stdout;
  flush stderr;
  let saved_stdout = Unix.dup Unix.stdout in
  let saved_stderr = Unix.dup Unix.stderr in
  let out_r, out_w = Unix.pipe ~cloexec:true () in
  let err_r, err_w = Unix.pipe ~cloexec:true () in
  Unix.dup2 out_w Unix.stdout;
  Unix.dup2 err_w Unix.stderr;
  Unix.close out_w;
  Unix.close err_w;
  let buf_out = Buffer.create 256 in
  let buf_err = Buffer.create 256 in
  let t_out = Thread.create (fun () -> drain out_r buf_out) () in
  let t_err = Thread.create (fun () -> drain err_r buf_err) () in
  let cleanup () =
    Format.pp_print_flush Format.std_formatter ();
    Format.pp_print_flush Format.err_formatter ();
    flush stdout;
    flush stderr;
    Unix.dup2 saved_stdout Unix.stdout;
    Unix.dup2 saved_stderr Unix.stderr;
    Unix.close saved_stdout;
    Unix.close saved_stderr;
    Thread.join t_out;
    Thread.join t_err
  in
  match f () with
  | result ->
      cleanup ();
      (result, Buffer.contents buf_out, Buffer.contents buf_err)
  | exception e ->
      cleanup ();
      raise e
