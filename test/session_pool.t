Named local sessions: a single MCP server fronts two `topup --socket`
daemons stood up by the cram script. The
`TOPUP_SESSION_SOCKET_<NAME>` environment hook makes
`start_local_session` skip the subprocess spawn and connect to a
pre-existing socket directly — same shape as the `TOPUP_HOST_SOCKET_*`
hook in `host_routing.t`.

Hermetic sandbox: phrase log off, host persistence off, session
persistence off. Spill under the cram dir. Checkpoint dir shared so
the two daemons see each other's checkpoints.

  $ export TOPUP_LOG=off
  $ export TOPUP_HOSTS_FILE=off
  $ export TOPUP_SESSIONS_FILE=off
  $ export TOPUP_SPILL_DIR="$PWD/spill"
  $ export TOPUP_CHECKPOINT_DIR="$PWD/ckpt"
  $ mkdir -p "$TOPUP_CHECKPOINT_DIR"

Stand up two `topup --socket` daemons that will play the role of
named sessions "a" and "b". They each need their own log/checkpoint
dir so they don't clobber each other; the checkpoint dir is shared so
branching is visible.

  $ TOPUP_LOG="$PWD/a.log" topup --socket "$PWD/a.sock" &
  $ A_PID=$!
  $ TOPUP_LOG="$PWD/b.log" topup --socket "$PWD/b.sock" &
  $ B_PID=$!
  $ trap 'kill "$A_PID" "$B_PID" "$LOCAL_PID" 2>/dev/null; wait 2>/dev/null' EXIT
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S a.sock ] && [ -S b.sock ]; then break; fi
  >   sleep 0.1
  > done

Start the front server. Two session hooks tell `start_local_session`
to use the daemons we already have, no subprocess spawn.

  $ TOPUP_SESSION_SOCKET_A="$PWD/a.sock" \
  > TOPUP_SESSION_SOCKET_B="$PWD/b.sock" \
  > topup --socket "$PWD/local.sock" &
  $ LOCAL_PID=$!
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S local.sock ]; then break; fi
  >   sleep 0.1
  > done

`start_local_session` brings up session "a", then session "b".

  $ printf '%s\n%s\n' \
  >   '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"start_local_session","arguments":{"session":"a"}}}' \
  >   '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"start_local_session","arguments":{"session":"b"}}}' \
  >   | topup --proxy "$PWD/local.sock" \
  >   | grep -c '\\"ok\\":true'
  2

Bindings on "a" do NOT leak to "b" — the subprocesses are isolated.

  $ printf '%s\n%s\n' \
  >   '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"eval","arguments":{"session":"a","source":"let x = 11 * 11;;"}}}' \
  >   '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"eval","arguments":{"session":"b","source":"x;;"}}}' \
  >   | topup --proxy "$PWD/local.sock" > out.json
  $ grep -c '\\"value_repr\\":\\"121\\"' out.json
  1
  $ grep -c '\\"phase\\":\\"typecheck\\"' out.json
  1

Branching via shared checkpoint dir: checkpoint on "a", restore on
"b", then look up `x` through session "b". The restore response
itself contains the replayed phrase's value_repr; the subsequent eval
returns it again — two occurrences total.

  $ printf '%s\n%s\n%s\n' \
  >   '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"checkpoint","arguments":{"session":"a","label":"p1"}}}' \
  >   '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"restore","arguments":{"session":"b","label":"p1"}}}' \
  >   '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"eval","arguments":{"session":"b","source":"x;;"}}}' \
  >   | topup --proxy "$PWD/local.sock" > branched.json
  $ grep -c '\\"value_repr\\":\\"121\\"' branched.json
  2

`reset` on "a" does not disturb "b" — full isolation.

  $ printf '%s\n%s\n' \
  >   '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"reset","arguments":{"session":"a"}}}' \
  >   '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"eval","arguments":{"session":"b","source":"x;;"}}}' \
  >   | topup --proxy "$PWD/local.sock" \
  >   | grep -c '\\"value_repr\\":\\"121\\"'
  1

`session:` and `host:` at once is a routing error.

  $ printf '%s\n' \
  >   '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"eval","arguments":{"session":"a","host":"h","source":"1;;"}}}' \
  >   | topup --proxy "$PWD/local.sock" \
  >   | grep -c 'mutually exclusive'
  1

`initialize` advertises the registered sessions in the `instructions`
block.

  $ printf '%s\n' '{"jsonrpc":"2.0","id":11,"method":"initialize"}' \
  >   | topup --proxy "$PWD/local.sock" \
  >   | grep -c 'Known sessions'
  1

Clean up.

  $ kill "$LOCAL_PID" "$A_PID" "$B_PID"
  $ wait 2>/dev/null
  $ trap - EXIT
