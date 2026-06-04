End-to-end coverage of `compile_to_binary`. The phrase log is the
source of truth; the tool synthesises a dune project around it,
builds, and copies the resulting executable to `out/main.exe`.

Hermetic dirs so the cram fixture doesn't depend on `$HOME`.

  $ TOPUP_LOG="$PWD/history.ml" \
  > TOPUP_CHECKPOINT_DIR="$PWD/ckpt" \
  > TOPUP_SPILL_DIR="$PWD/spill" \
  > topup --socket "$PWD/topup.sock" &
  $ SERVER_PID=$!
  $ trap 'kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null' EXIT
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S topup.sock ]; then break; fi
  >   sleep 0.1
  > done

Define a small program in the toplevel: a value and a `main` that
prints it.

  $ ./socket_client.bc.exe topup.sock eval "let answer = 42;;"
  42
  $ ./socket_client.bc.exe topup.sock eval "let main () = print_endline (string_of_int answer);;"
  <fun>

Promote. The tool synthesises dune-project/dune/main.ml under the
output dir, builds, and reports the binary path.

  $ ./socket_client.bc.exe topup.sock compile main "$PWD/promoted" | grep -o '^ok'
  ok

The binary lands at `out/main.exe` and runs natively, no topup
dependency.

  $ "$PWD/promoted/main.exe"
  42

The synthesised sources are inspectable in `out/`. main.ml ends with
the wrapper line.

  $ tail -1 "$PWD/promoted/main.ml"
  let () = ignore (main ())

A second promote against the same `out` directory works (the prior
run left a .topup-promote marker so re-runs are allowed).

  $ ./socket_client.bc.exe topup.sock compile main "$PWD/promoted" | grep -o '^ok'
  ok

A failing build: `entry` names something undefined. `ok = false`,
the dune error appears in `build_log`.

  $ ./socket_client.bc.exe topup.sock compile no_such_binding "$PWD/promoted-bad" 2>&1 | grep -o 'Unbound value'
  Unbound value

A non-empty `out` directory without the marker is refused.

  $ mkdir "$PWD/dirty" && touch "$PWD/dirty/random-file"
  $ ./socket_client.bc.exe topup.sock compile main "$PWD/dirty" 2>&1 | grep -o 'topup-promote marker'
  topup-promote marker

Shutdown unlinks the socket file.

  $ kill "$SERVER_PID"
  $ wait "$SERVER_PID" 2>/dev/null
  $ trap - EXIT
  $ [ -e topup.sock ] && echo "leak" || echo ok
  ok
