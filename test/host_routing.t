Multi-host routing without SSH. Two `topup --socket` daemons stand in
for "local" and "remote"; the routing test points one MCP server (the
"local" daemon) at the other via the `TOPUP_HOST_SOCKET_<HOST>`
testing hook so `start_session` skips the SSH spawn.

Hermetic sandbox: phrase log off, spill under the cram dir, host
persistence off.

  $ export TOPUP_LOG=off
  $ export TOPUP_SPILL_DIR="$PWD/spill"
  $ export TOPUP_HOSTS_FILE=off

Start the "remote" daemon — this is the topup the routed calls land on.

  $ topup --socket "$PWD/remote.sock" &
  $ REMOTE_PID=$!
  $ trap 'kill "$REMOTE_PID" $LOCAL_PID 2>/dev/null; wait 2>/dev/null' EXIT
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S remote.sock ]; then break; fi
  >   sleep 0.1
  > done

Start the "local" daemon — this is the one we'll send routed requests
to. The env-var hook tells `start_session` to use the cram-local
socket instead of spawning SSH.

  $ TOPUP_HOST_SOCKET_TESTHOST="$PWD/remote.sock" \
  > topup --socket "$PWD/local.sock" &
  $ LOCAL_PID=$!
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S local.sock ]; then break; fi
  >   sleep 0.1
  > done

`initialize` against the local daemon advertises the local session
in the `instructions` block.

  $ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
  >   | topup --proxy "$PWD/local.sock" \
  >   | grep -c 'Known hosts'
  1

`start_session { host: "testhost" }` brings the route up. The success
payload (a JSON string in the MCP `text` content) carries `\"ok\":true`.

  $ printf '%s\n' \
  >   '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"start_session","arguments":{"host":"testhost"}}}' \
  >   | topup --proxy "$PWD/local.sock" \
  >   | grep -c '\\"ok\\":true'
  1

Bind a value on the routed host, then read it back through a second
routed call. State must persist on the remote daemon.

  $ printf '%s\n%s\n%s\n' \
  >   '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"start_session","arguments":{"host":"testhost"}}}' \
  >   '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"eval","arguments":{"host":"testhost","source":"let routed = 11 * 11;;"}}}' \
  >   '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"eval","arguments":{"host":"testhost","source":"routed;;"}}}' \
  >   | topup --proxy "$PWD/local.sock" > out.json
  $ grep -c '\\"value_repr\\":\\"121\\"' out.json
  2

A call with no host stays local — the binding above must NOT be
visible.

  $ printf '%s\n' \
  >   '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"eval","arguments":{"source":"routed;;"}}}' \
  >   | topup --proxy "$PWD/local.sock" \
  >   | grep -c '\\"phase\\":\\"typecheck\\"'
  1

An unknown host returns a structured error rather than crashing.

  $ printf '%s\n' \
  >   '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"eval","arguments":{"host":"nope","source":"1+1;;"}}}' \
  >   | topup --proxy "$PWD/local.sock" \
  >   | grep -c '"isError":true'
  1

`update_host` succeeds and the description shows up in `initialize`'s
`instructions` block next time.

  $ printf '%s\n%s\n' \
  >   '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"update_host","arguments":{"host":"testhost","description":"cram fixture"}}}' \
  >   '{"jsonrpc":"2.0","id":9,"method":"initialize"}' \
  >   | topup --proxy "$PWD/local.sock" \
  >   | grep -c 'cram fixture'
  1

Clean up.

  $ kill "$LOCAL_PID" "$REMOTE_PID"
  $ wait 2>/dev/null
  $ trap - EXIT
