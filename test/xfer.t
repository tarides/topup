Local↔remote file transfer. Two `topup --socket` daemons stand in for
"local" and "remote"; `TOPUP_HOST_SOCKET_<HOST>` skips the SSH spawn so
the local daemon's `start_session` connects directly to the colocated
remote daemon.

Hermetic sandbox.

  $ export TOPUP_LOG=off
  $ export TOPUP_SPILL_DIR="$PWD/spill"
  $ export TOPUP_HOSTS_FILE=off
  $ export TOPUP_XFER_DIR="$PWD/xfer"
  $ mkdir -p "$TOPUP_XFER_DIR"

Spawn the remote daemon.

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

Create a local input file (small, well under the 16 MiB cap).

  $ printf 'hello,world\n42,life\n' > input.csv
  $ wc -c < input.csv | tr -d ' '
  20

`push_file` with explicit `remote_path` copies the bytes to the remote
daemon's filesystem.

  $ printf '%s\n' \
  >   '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"push_file","arguments":{"host":"testhost","local_path":"input.csv","remote_path":"'$PWD'/xfer/input-pushed.csv"}}}' \
  >   | topup --proxy "$PWD/local.sock" > push_out.json
  $ grep -c '\\"bytes\\":20' push_out.json
  1
  $ cmp input.csv xfer/input-pushed.csv && echo same
  same

The remote OCaml session can `open_in` the pushed file.

  $ printf '%s\n' \
  >   '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"eval","arguments":{"host":"testhost","source":"let ic = open_in \"'$PWD'/xfer/input-pushed.csv\" in let n = in_channel_length ic in close_in ic; n;;"}}}' \
  >   | topup --proxy "$PWD/local.sock" \
  >   | grep -c '\\"value_repr\\":\\"20\\"'
  1

`pull_file` brings the bytes back.

  $ printf '%s\n' \
  >   '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"pull_file","arguments":{"host":"testhost","remote_path":"'$PWD'/xfer/input-pushed.csv","local_path":"'$PWD'/xfer/round-trip.csv"}}}' \
  >   | topup --proxy "$PWD/local.sock" > pull_out.json
  $ grep -c '\\"bytes\\":20' pull_out.json
  1
  $ cmp input.csv xfer/round-trip.csv && echo same
  same

Default destinations use `TOPUP_XFER_DIR/<basename>` on each side.

  $ printf '%s\n' \
  >   '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"push_file","arguments":{"host":"testhost","local_path":"input.csv"}}}' \
  >   | topup --proxy "$PWD/local.sock" > push_default.json
  $ grep -c 'remote_path' push_default.json
  1
  $ cmp input.csv xfer/input.csv && echo same
  same

Without `host:`, `push_file` is rejected (the boundary is local↔remote).

  $ printf '%s\n' \
  >   '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"push_file","arguments":{"local_path":"input.csv"}}}' \
  >   | topup --proxy "$PWD/local.sock" \
  >   | grep -c "'host' is required"
  1

`session:` is also rejected (mutually exclusive with `host:`).

  $ printf '%s\n' \
  >   '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"push_file","arguments":{"host":"testhost","session":"foo","local_path":"input.csv"}}}' \
  >   | topup --proxy "$PWD/local.sock" \
  >   | grep -c 'mutually exclusive'
  1

Oversized files are refused before any bytes leave the disk. The cap
lives in the *local* daemon (it reads the file size before sending),
so we restart the local daemon under a stricter `TOPUP_XFER_MAX_BYTES`
to exercise it. The remote daemon stays up; the local daemon's
`start_session` re-attaches via the same env-hook socket.

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
  >   '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"push_file","arguments":{"host":"testhost","local_path":"'$PWD'/big.bin"}}}' \
  >   | topup --proxy "$PWD/local.sock" \
  >   | grep -c 'file too large'
  1

`tools/list` advertises `push_file` and `pull_file` but hides the
internal `_recv_blob` / `_send_blob` primitives.

  $ printf '%s\n' \
  >   '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  >   | topup --proxy "$PWD/local.sock" > tools.json
  $ grep -c '"name":"push_file"' tools.json
  1
  $ grep -c '"name":"pull_file"' tools.json
  1
  $ grep -q '"name":"_recv_blob"' tools.json && echo leak || echo hidden
  hidden
  $ grep -q '"name":"_send_blob"' tools.json && echo leak || echo hidden
  hidden

Clean up.

  $ kill "$LOCAL_PID" "$REMOTE_PID"
  $ wait 2>/dev/null
  $ trap - EXIT
