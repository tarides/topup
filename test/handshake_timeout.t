Regression test for the read-side handshake timeout. A daemon that
accepts the connection but never writes back (because it's wedged, or
because it's a stale process that lost the socket race) used to block
`start_session` forever in `input_line`. `Remote_host` now sets
`SO_RCVTIMEO` for the duration of the `initialize` handshake so the
read aborts after `handshake_read_timeout` seconds and the call
returns a structured error.

  $ export TOPUP_LOG=off
  $ export TOPUP_HOSTS_FILE=off
  $ export TOPUP_HOST_SOCKET_DEAFHOST="$PWD/deaf.sock"

Bring up a deaf Unix-socket server in place of the daemon.

  $ ./deaf_socket_server.bc.exe "$PWD/deaf.sock" >/dev/null &
  $ DEAF_PID=$!
  $ trap 'kill "$DEAF_PID" 2>/dev/null; wait 2>/dev/null' EXIT
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S deaf.sock ]; then break; fi
  >   sleep 0.1
  > done

`start_session { host: "deafhost" }` against the deaf server returns a
`connect`-phase error containing "handshake timed out". The call must
return — a hung run would block the cram suite indefinitely.

  $ printf '%s\n%s\n' \
  >   '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
  >   '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"start_session","arguments":{"host":"deafhost"}}}' \
  > | topup \
  > | grep -c 'handshake timed out'
  1

  $ kill "$DEAF_PID"
  $ wait 2>/dev/null
  $ trap - EXIT
