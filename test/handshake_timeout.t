Regression test for the read-side handshake timeout. A daemon that
accepts the connection but never writes back (because it's wedged, or
because it's a stale process that lost the socket race) used to block
`start_session` forever in `input_line`. `Remote_host` now bounds the
`initialize` handshake read with a `select`-based deadline
(`Rpc.read_message_deadline`, `handshake_read_timeout` seconds) so the
read aborts and the call returns a structured error. A `select`
deadline is used rather than `SO_RCVTIMEO` because the latter does not
interrupt a blocking read on all platforms (it hung on macOS/arm64).

  $ export TOPUP_LOG=off
  $ export TOPUP_HOSTS_FILE=off
  $ export TOPUP_HOST_SOCKET_DEAFHOST=deaf.sock

Bring up a deaf Unix-socket server in place of the daemon.

  $ ./deaf_socket_server.bc.exe deaf.sock >/dev/null &
  $ DEAF_PID=$!
  $ trap 'kill "$DEAF_PID" 2>/dev/null; wait 2>/dev/null' EXIT
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S deaf.sock ]; then break; fi
  >   sleep 0.1
  > done

`start_session { host: "deafhost" }` against the deaf server returns a
`connect`-phase error containing "handshake timed out". The call must
return — a hung run would block the cram suite indefinitely. As a
belt-and-braces guard against a future regression that reintroduces the
hang, run `topup` under a portable watchdog that SIGKILLs it after ~60s
so the test fails fast (empty output) instead of stalling CI for hours.

  $ printf '%s\n%s\n' \
  >   '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
  >   '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"start_session","arguments":{"host":"deafhost"}}}' \
  >   > req.json
  $ topup < req.json > resp.json 2>/dev/null &
  $ TP=$!
  $ ( n=0
  >   while kill -0 "$TP" 2>/dev/null; do
  >     n=$((n + 1))
  >     if [ "$n" -ge 120 ]; then kill -9 "$TP" 2>/dev/null; break; fi
  >     sleep 0.5
  >   done ) &
  $ WD=$!
  $ wait "$TP" 2>/dev/null
  $ wait "$WD" 2>/dev/null
  $ grep -c 'handshake timed out' resp.json
  1

  $ kill "$DEAF_PID"
  $ wait 2>/dev/null
  $ trap - EXIT
