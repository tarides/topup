End-to-end coverage of the native driver (`topup-opt`). Mirrors
`socket.t`'s shape but spawns the native binary — each user phrase is
compiled with `ocamlopt -shared` and Dynlink-loaded into the running
process.

  $ TOPUP_LOG=off TOPUP_SPILL_DIR="$PWD/spill" topup-opt --socket "$PWD/topup.sock" &
  $ SERVER_PID=$!
  $ trap 'kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null' EXIT
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S topup.sock ]; then break; fi
  >   sleep 0.1
  > done

Persistent typed bindings across connections — the externalized-memory
thesis still holds when phrases compile to native.

  $ ./socket_client.bc.exe topup.sock eval "let x = 21 * 2;;"
  42
  $ ./socket_client.bc.exe topup.sock eval "let greet name = \"hi, \" ^ name;;"
  <fun>
  $ ./socket_client.bc.exe topup.sock eval "x;;"
  42
  $ ./socket_client.bc.exe topup.sock eval "greet \"opt\";;"
  "hi, opt"

`env` and `lookup` see the same user-defined bindings.

  $ ./socket_client.bc.exe topup.sock env
  greet : string -> string
  x : int
  $ ./socket_client.bc.exe topup.sock lookup x
  x : int
  $ ./socket_client.bc.exe topup.sock lookup nope
  (not found)

Type errors land in the eval payload's `error.message`, same as
bytecode.

  $ ./socket_client.bc.exe topup.sock eval "x +. 1.0;;"
  ERROR: The value x has type int but an expression was expected of type float

Custom printers survive the native path — `#install_printer` is the
highest-risk surface; the Outcometree hook still picks up the
user-supplied formatter.

  $ ./socket_client.bc.exe topup.sock eval "type box = { tag : string; v : int };; let pp_box ppf b = Format.fprintf ppf \"<%s:%d>\" b.tag b.v;; #install_printer pp_box;;"
  <fun>
  $ ./socket_client.bc.exe topup.sock eval "{ tag = \"hi\"; v = 42 };;"
  <hi:42>

A forever-loop phrase with `timeout: 0.5` returns the `evaluation timed
out` runtime error within the cap (SIGINT delivery into a Dynlinked
.cmxs works the same way as in bytecode).

  $ ./socket_client.bc.exe topup.sock request '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"eval","arguments":{"source":"while true do () done;;","timeout":0.5}}}' | grep -o 'evaluation timed out'
  evaluation timed out

`load` accepts a native `.cmxs` under topup-opt; the loaded module is
reachable from a subsequent eval.

  $ ./socket_client.bc.exe topup.sock load "$PWD/fixtures/topup_load_fixture/topup_load_fixture.cmxs"
  ok
  $ ./socket_client.bc.exe topup.sock eval "Topup_load_fixture.answer;;"
  42

Passing a `.cma` under the native driver fails with a clear
backend-mismatch message, not an opaque Dynlink diagnostic.

  $ ./socket_client.bc.exe topup.sock request '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"load","arguments":{"path":"'"$PWD"'/fixtures/topup_load_fixture/topup_load_fixture.cma"}}}' | grep -o 'this driver accepts \.cmxs'
  this driver accepts .cmxs

A non-existent path with the right extension surfaces a clear
file-not-found error rather than Topdirs' silent swallow.

  $ ./socket_client.bc.exe topup.sock request '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"load","arguments":{"path":"'"$PWD"'/no-such-archive.cmxs"}}}' | grep -o 'load: file not found'
  load: file not found

`reset` discards user state; `env` afterwards is empty.

  $ ./socket_client.bc.exe topup.sock reset
  ok
  $ ./socket_client.bc.exe topup.sock env
  (empty)
  $ ./socket_client.bc.exe topup.sock lookup x
  (not found)

Shutdown unlinks the socket file.

  $ kill "$SERVER_PID"
  $ wait "$SERVER_PID" 2>/dev/null
  $ trap - EXIT
  $ [ -e topup.sock ] && echo "leak" || echo ok
  ok
