End-to-end coverage of the five MCP tools driven over the Unix socket
transport. Each call to `socket_client.bc.exe` opens a fresh
connection, so every assertion below is also an assertion that state
survives between connections.

Disable history-logging and redirect spill to the cram sandbox so the
fixture is hermetic.

  $ TOPUP_LOG=off TOPUP_SPILL_DIR="$PWD/spill" topup --socket "$PWD/topup.sock" &
  $ SERVER_PID=$!
  $ trap 'kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null' EXIT
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S topup.sock ]; then break; fi
  >   sleep 0.1
  > done

Define two bindings and read one back from a separate connection.

  $ ./socket_client.bc.exe topup.sock eval "let x = 21 * 2;;"
  42
  $ ./socket_client.bc.exe topup.sock eval "let greet name = \"hi, \" ^ name;;"
  <fun>
  $ ./socket_client.bc.exe topup.sock eval "x;;"
  42
  $ ./socket_client.bc.exe topup.sock eval "greet \"topup\";;"
  "hi, topup"

`env` enumerates user-defined bindings, sorted.

  $ ./socket_client.bc.exe topup.sock env
  greet : string -> string
  x : int

`lookup` returns the type of a known binding, "(not found)" otherwise.

  $ ./socket_client.bc.exe topup.sock lookup x
  x : int
  $ ./socket_client.bc.exe topup.sock lookup nope
  (not found)

A type error surfaces via the eval payload's `error.message`.

  $ ./socket_client.bc.exe topup.sock eval "x +. 1.0;;"
  ERROR: The value x has type int but an expression was expected of type float

`load` dynlinks a bytecode `.cma`; the loaded module is reachable from
a subsequent connection.

  $ ./socket_client.bc.exe topup.sock load "$PWD/fixtures/topup_load_fixture/topup_load_fixture.cma"
  ok
  $ ./socket_client.bc.exe topup.sock eval "Topup_load_fixture.answer;;"
  42
  $ ./socket_client.bc.exe topup.sock eval "Topup_load_fixture.greet \"socket\";;"
  "hi from fixture, socket"

Passing a `.cmxs` under the bytecode driver fails with a clear
backend-mismatch message, and a non-existent path surfaces a clear
not-found error rather than Topdirs' silent swallow.

  $ ./socket_client.bc.exe topup.sock request '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"load","arguments":{"path":"'"$PWD"'/fixtures/topup_load_fixture/topup_load_fixture.cmxs"}}}' | grep -o 'this driver accepts \.cma'
  this driver accepts .cma
  $ ./socket_client.bc.exe topup.sock request '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"load","arguments":{"path":"'"$PWD"'/no-such-archive.cma"}}}' | grep -o 'load: file not found'
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
