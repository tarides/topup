Back-channel `Topup.read_back` / `Topup.write_back` from inside a
routed `eval`. Two `topup --socket` daemons stand in for "local" and
"remote"; `TOPUP_HOST_SOCKET_TESTHOST` skips the SSH spawn so the
local daemon's `start_session` connects directly to the colocated
remote daemon.

Hermetic sandbox.

  $ export TOPUP_LOG=off
  $ export TOPUP_SPILL_DIR="$PWD/spill"
  $ export TOPUP_HOSTS_FILE=off
  $ export TOPUP_XFER_DIR="$PWD/xfer"
  $ mkdir -p "$TOPUP_XFER_DIR"

Spawn the remote daemon. Its `Topup_runtime` hook will be replaced
by the muxed hook when the local daemon connects, so a routed
`Topup.read_back` reaches back across the SSH-substitute socket
rather than reading from the remote's own filesystem.

  $ topup --socket "$PWD/remote.sock" &
  $ REMOTE_PID=$!
  $ trap 'kill "$REMOTE_PID" $LOCAL_PID 2>/dev/null; wait 2>/dev/null' EXIT
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S remote.sock ]; then break; fi
  >   sleep 0.1
  > done

Spawn the local daemon with the test hook pointing at the remote.

  $ TOPUP_HOST_SOCKET_TESTHOST="$PWD/remote.sock" \
  > topup --socket "$PWD/local.sock" &
  $ LOCAL_PID=$!
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S local.sock ]; then break; fi
  >   sleep 0.1
  > done

Bring the route up.

  $ printf '%s\n' \
  >   '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"start_session","arguments":{"host":"testhost"}}}' \
  >   | topup --proxy "$PWD/local.sock" \
  >   | grep -c '\\"ok\\":true'
  1

Put a file on the *local* daemon's filesystem (this is the
chatbot's filesystem in production).

  $ printf 'back-channel payload\n' > input.bin
  $ wc -c < input.bin | tr -d ' '
  21

Round-trip via the back channel: a routed `eval` on testhost reads
the bytes from local, writes them back to a different local path.
The remote daemon never sees the file directly — every byte flows
over the back channel.

  $ printf '%s\n' \
  >   '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"eval","arguments":{"host":"testhost","source":"let b = Topup.read_back \"'$PWD'/input.bin\" in Topup.write_back \"'$PWD'/round-trip.bin\" b; Bytes.length b;;"}}}' \
  >   | topup --proxy "$PWD/local.sock" \
  >   | grep -c '\\"value_repr\\":\\"21\\"'
  1
  $ cmp input.bin round-trip.bin && echo same
  same

A read that would exceed `TOPUP_XFER_MAX_BYTES` raises a clear
error inside the routed eval. The cap is honoured on the *local*
side (where the bytes live); the remote's `Topup.read_back`
surfaces the error message in its exception.

  $ kill "$LOCAL_PID" 2>/dev/null
  $ wait "$LOCAL_PID" 2>/dev/null
  $ head -c 4096 /dev/zero > big.bin
  $ TOPUP_HOST_SOCKET_TESTHOST="$PWD/remote.sock" \
  > TOPUP_XFER_MAX_BYTES=1024 \
  > topup --socket "$PWD/local.sock" &
  $ LOCAL_PID=$!
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S local.sock ]; then break; fi
  >   sleep 0.1
  > done
  $ printf '%s\n%s\n' \
  >   '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"start_session","arguments":{"host":"testhost"}}}' \
  >   '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"eval","arguments":{"host":"testhost","source":"let _ = Topup.read_back \"'$PWD'/big.bin\" in ();;"}}}' \
  >   | topup --proxy "$PWD/local.sock" \
  >   | grep -c 'file too large'
  1
