Stdio↔socket bridge (`topup --proxy`). The bridge forwards bytes in
both directions; this fixture drives a long-running `topup --socket`
daemon through it via raw JSON-RPC on stdin / stdout.

Hermetic sandbox: phrase log off, spill under the cram dir.

  $ TOPUP_LOG=off TOPUP_SPILL_DIR="$PWD/spill" topup --socket "$PWD/server.sock" &
  $ SERVER_PID=$!
  $ trap 'kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null' EXIT
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S server.sock ]; then break; fi
  >   sleep 0.1
  > done

A single `initialize` exchange end-to-end: proxy connects to the
daemon, forwards the request, returns the response.

  $ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
  >   | topup --proxy "$PWD/server.sock"
  {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"topup","version":"0.1.0"}}}

State persists across separate proxy invocations: bind `x` in one,
read it back in another. The bridge is a transient byte pump; the
session lives in the long-running socket daemon.

  $ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"eval","arguments":{"source":"let x = 21 * 2;;"}}}' \
  >   | topup --proxy "$PWD/server.sock" \
  >   | grep -o '\\"value_repr\\":\\"42\\"'
  \"value_repr\":\"42\"

  $ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"eval","arguments":{"source":"x;;"}}}' \
  >   | topup --proxy "$PWD/server.sock" \
  >   | grep -o '\\"value_repr\\":\\"42\\"'
  \"value_repr\":\"42\"

Multiple requests batched on a single proxy invocation ride one
connection; the daemon sees them in order and replies in order.

  $ printf '%s\n%s\n' \
  >   '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"env","arguments":{}}}' \
  >   '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"reset","arguments":{}}}' \
  >   | topup --proxy "$PWD/server.sock" > batch.out
  $ grep -c '"id":2' batch.out
  1
  $ grep -c '"id":3' batch.out
  1

Daemon shutdown still unlinks the socket file.

  $ kill "$SERVER_PID"
  $ wait "$SERVER_PID" 2>/dev/null
  $ trap - EXIT
  $ [ -e server.sock ] && echo leak || echo ok
  ok
