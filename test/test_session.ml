open Topup

let check label want got =
  if want <> got then begin
    Printf.printf "FAIL %s: want %s, got %s\n%!" label want got;
    exit 1
  end

let () =
  let s = Session.create () in
  let r1 = Session.eval s "let x = 1 + 2;;" in
  check "let-x value_repr" "3" (Option.value ~default:"<none>" r1.value_repr);
  check "let-x ty" "int" (Option.value ~default:"<none>" r1.ty);
  let r2 = Session.eval s "x * 10;;" in
  check "x*10 value_repr" "30" (Option.value ~default:"<none>" r2.value_repr);
  check "x*10 ty" "int" (Option.value ~default:"<none>" r2.ty);
  let r3 = Session.eval s {|print_endline "hi"; 1;;|} in
  check "capture stdout" "hi\n" r3.stdout;
  check "capture value_repr" "1" (Option.value ~default:"<none>" r3.value_repr);
  let r4 = Session.eval s "let y = 1 + true;;" in
  (match r4.error with
   | Some { phase = Typecheck; location = Some _; _ } -> ()
   | Some { phase; location; message; _ } ->
       Printf.printf
         "FAIL typecheck error shape: phase=%s location=%s msg=%s\n%!"
         (match phase with
          | Topup.Error.Typecheck -> "typecheck"
          | Runtime -> "runtime")
         (match location with Some _ -> "some" | None -> "none")
         message;
       exit 1
   | None ->
       print_endline "FAIL typecheck: no error returned";
       exit 1);
  let r5 = Session.eval s {|raise (Failure "boom");;|} in
  (match r5.error with
   | Some { phase = Runtime; message; _ }
     when String.length message > 0 -> ()
   | _ ->
       print_endline "FAIL runtime error not surfaced";
       exit 1);
  let _ = Session.eval s "let alpha = 7;;" in
  let _ = Session.eval s "let beta = \"b\";;" in
  let bindings = Session.env s in
  let has n = List.exists (fun (b : Session.binding) -> b.name = n) bindings in
  if not (has "alpha" && has "beta" && has "x") then begin
    print_endline "FAIL env listing missing user entries";
    exit 1
  end;
  if List.exists
       (fun (b : Session.binding) -> b.name = "print_endline")
       bindings
  then begin
    print_endline "FAIL env default leaked stdlib bindings";
    exit 1
  end;
  let all_bindings = Session.env ~all:true s in
  if not
       (List.exists
          (fun (b : Session.binding) -> b.name = "print_endline")
          all_bindings)
  then begin
    print_endline "FAIL env ~all:true missed stdlib bindings";
    exit 1
  end;
  (match Session.lookup s "alpha" with
   | Some { ty = "int"; _ } -> ()
   | _ ->
       print_endline "FAIL lookup alpha";
       exit 1);
  (match Session.lookup s "no_such_name" with
   | None -> ()
   | Some _ ->
       print_endline "FAIL lookup returned for missing";
       exit 1);
  (match Session.env s ~filter:"alph" with
   | [ { name = "alpha"; _ } ] -> ()
   | xs ->
       Printf.printf "FAIL env filter: %d results\n" (List.length xs);
       exit 1);
  Session.reset s;
  (match Session.lookup s "alpha" with
   | None -> ()
   | Some _ ->
       print_endline "FAIL reset did not clear bindings";
       exit 1);
  let r_after_reset = Session.eval s "alpha;;" in
  (match r_after_reset.error with
   | Some { phase = Typecheck; _ } -> ()
   | _ ->
       print_endline "FAIL eval after reset should be unbound";
       exit 1);
  let t0 = Unix.gettimeofday () in
  let r_to = Session.eval ~timeout:0.2 s "let rec f () = f () in f ();;" in
  let elapsed = Unix.gettimeofday () -. t0 in
  (match r_to.error with
   | Some { phase = Runtime; message = "evaluation timed out"; _ }
     when elapsed < 1.0 -> ()
   | _ ->
       Printf.printf "FAIL timeout: elapsed=%.3f err=%s\n" elapsed
         (match r_to.error with
          | Some e -> e.message
          | None -> "<no error>");
       exit 1);
  let r_long = Session.eval s "List.init 10000 (fun i -> i);;" in
  (match r_long.value_repr with
   | Some s when String.length s <= !Topup.Pretty.max_bytes + 64 -> ()
   | Some s ->
       Printf.printf "FAIL oversized value_repr: %d bytes\n" (String.length s);
       exit 1
   | None ->
       print_endline "FAIL oversized: no value_repr";
       exit 1);
  let saved = !Topup.Pretty.max_bytes in
  Topup.Pretty.max_bytes := 16;
  let r_tiny =
    Session.eval s "\"123456789012345678901234567890\";;"
  in
  Topup.Pretty.max_bytes := saved;
  (match r_tiny.value_repr with
   | Some s when String.length s <= 16 + 32 && String.length s > 16 -> ()
   | Some s ->
       Printf.printf "FAIL tight cap: got %d bytes: %s\n" (String.length s) s;
       exit 1
   | None ->
       print_endline "FAIL tight cap: no value_repr";
       exit 1);
  let log_path =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "topup-test-log-%d.ml" (Unix.getpid ()))
  in
  (try Sys.remove log_path with _ -> ());
  let s_logged = Session.create ~log_path () in
  let _ = Session.eval s_logged "let logged_one = 11;;" in
  let _ = Session.eval s_logged "let logged_two = logged_one * 4;;" in
  let _ = Session.eval s_logged "let _bad = 1 + true;;" in
  let logged =
    let ic = open_in log_path in
    let n = in_channel_length ic in
    let buf = Bytes.create n in
    really_input ic buf 0 n;
    close_in ic;
    Bytes.unsafe_to_string buf
  in
  let contains_sub hay needle =
    let n = String.length hay and k = String.length needle in
    let rec loop i =
      if i + k > n then false
      else if String.sub hay i k = needle then true
      else loop (i + 1)
    in
    k > 0 && loop 0
  in
  if not (contains_sub logged "logged_one") then begin
    Printf.printf "FAIL log missing entries; got: %S\n" logged;
    exit 1
  end;
  if contains_sub logged "_bad" then begin
    print_endline "FAIL log included a phrase that errored";
    exit 1
  end;
  Session.reset s_logged;
  let _ = Session.eval s_logged (Printf.sprintf "#use %S;;" log_path) in
  (match Session.lookup s_logged "logged_two" with
   | Some { ty = "int"; _ } -> ()
   | _ ->
       print_endline "FAIL replay via #use did not restore logged_two";
       exit 1);
  (try Sys.remove log_path with _ -> ());
  print_endline "test_session: ok"
