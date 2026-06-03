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
    print_endline "FAIL env listing missing entries";
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
  print_endline "test_session: ok"
