Back-channel confinement (TOPUP_BACKCHANNEL_ROOT). When the local
daemon talks to a remote it doesn't fully trust, a routed
`Topup.read_back` / `Topup.write_back` must not be able to reach
arbitrary local files: a `..` escape is rejected and an absolute path
is reinterpreted *under* the confinement root rather than at its real
location.

Same two-daemon, no-SSH topology as back_channel.t.

  $ export TOPUP_LOG=off
  $ export TOPUP_SPILL_DIR="$PWD/spill"
  $ export TOPUP_HOSTS_FILE=off

  $ topup --socket "$PWD/remote.sock" &
  $ REMOTE_PID=$!
  $ trap 'kill "$REMOTE_PID" $LOCAL_PID 2>/dev/null; wait 2>/dev/null' EXIT
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S remote.sock ]; then break; fi
  >   sleep 0.1
  > done

The confinement applies on the *local* daemon (it holds the back
channel), so set the root there.

  $ mkdir -p "$PWD/confined"
  $ TOPUP_HOST_SOCKET_TESTHOST="$PWD/remote.sock" \
  > TOPUP_BACKCHANNEL_ROOT="$PWD/confined" \
  > topup --socket "$PWD/local.sock" &
  $ LOCAL_PID=$!
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S local.sock ]; then break; fi
  >   sleep 0.1
  > done

A payload placed inside the root is readable by a relative path, and a
relative write lands inside the root.

  $ printf 'confined payload\n' > confined/input.bin
  $ printf '%s\n%s\n' \
  >   '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"start_session","arguments":{"host":"testhost"}}}' \
  >   '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"eval","arguments":{"host":"testhost","source":"let b = Topup.read_back \"input.bin\" in Topup.write_back \"out.bin\" b; Bytes.length b;;"}}}' \
  >   | topup --proxy "$PWD/local.sock" \
  >   | grep -c '\\"value_repr\\":\\"17\\"'
  1
  $ cmp confined/input.bin confined/out.bin && echo same
  same

A `..` traversal that climbs above the root is rejected.

  $ printf '%s\n%s\n' \
  >   '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"start_session","arguments":{"host":"testhost"}}}' \
  >   '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"eval","arguments":{"host":"testhost","source":"Topup.write_back \"../escaped.bin\" (Bytes.of_string \"x\");;"}}}' \
  >   | topup --proxy "$PWD/local.sock" \
  >   | grep -c 'escapes back-channel root'
  1
  $ [ -e escaped.bin ] && echo ESCAPED || echo safe
  safe

An absolute path is remapped under the root, never written at its real
location.

  $ printf '%s\n%s\n' \
  >   '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"start_session","arguments":{"host":"testhost"}}}' \
  >   '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"eval","arguments":{"host":"testhost","source":"Topup.write_back \"'$PWD'/abs-escape.bin\" (Bytes.of_string \"x\");;"}}}' \
  >   | topup --proxy "$PWD/local.sock" > /dev/null
  $ [ -e abs-escape.bin ] && echo ESCAPED || echo safe
  safe
  $ [ -e "confined$PWD/abs-escape.bin" ] && echo remapped || echo missing
  remapped

Clean up.

  $ kill "$LOCAL_PID" "$REMOTE_PID"
  $ wait 2>/dev/null
  $ trap - EXIT
