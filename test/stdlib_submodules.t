Regression test for stdlib submodules that `compiler-libs.toplevel`
does not transitively reference. dune's `byte_complete` mode used to
drop these from the linked image, so any `#require`'d package that
referenced (say) `Stdlib__ListLabels` would fail with "interface
loaded, implementation missing". `bin/dune` now passes `-linkall` to
the linker for the bytecode binary.

The same modules also work on `topup-opt`; native linking never had
the issue but the assertion guards against future regressions.

Byte driver — these aliases must resolve without `#require`.

  $ TOPUP_LOG=off TOPUP_SPILL_DIR="$PWD/spill" topup --socket "$PWD/byte.sock" &
  $ BYTE_PID=$!
  $ trap 'kill "$BYTE_PID" 2>/dev/null; wait "$BYTE_PID" 2>/dev/null' EXIT
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S byte.sock ]; then break; fi
  >   sleep 0.1
  > done

  $ ./socket_client.bc.exe byte.sock eval "ListLabels.length [1;2;3];;"
  3
  $ ./socket_client.bc.exe byte.sock eval "StringLabels.length \"abc\";;"
  3
  $ ./socket_client.bc.exe byte.sock eval "ArrayLabels.length [|1;2;3;4|];;"
  4

  $ kill "$BYTE_PID"
  $ wait "$BYTE_PID" 2>/dev/null
  $ trap - EXIT

Native driver — same assertion against `topup-opt`.

  $ TOPUP_LOG=off TOPUP_SPILL_DIR="$PWD/spill" topup-opt --socket "$PWD/native.sock" &
  $ OPT_PID=$!
  $ trap 'kill "$OPT_PID" 2>/dev/null; wait "$OPT_PID" 2>/dev/null' EXIT
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S native.sock ]; then break; fi
  >   sleep 0.1
  > done

  $ ./socket_client.bc.exe native.sock eval "ListLabels.length [1;2;3];;"
  3
  $ ./socket_client.bc.exe native.sock eval "StringLabels.length \"abc\";;"
  3
  $ ./socket_client.bc.exe native.sock eval "ArrayLabels.length [|1;2;3;4|];;"
  4

  $ kill "$OPT_PID"
  $ wait "$OPT_PID" 2>/dev/null
  $ trap - EXIT
