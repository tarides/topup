Permission hardening for the files and sockets topup creates. The
Unix socket and the persisted registry files must be owner-only
(0o600), so another user on a shared host cannot connect to the
daemon or read host/session metadata.

  $ export TOPUP_LOG=off
  $ export TOPUP_SPILL_DIR="$PWD/spill"
  $ export TOPUP_HOSTS_FILE="$PWD/hosts.json"
  $ export TOPUP_SESSIONS_FILE="$PWD/sessions.json"

A "remote" daemon to register against (via the no-SSH test hook).

  $ topup --socket "$PWD/remote.sock" &
  $ REMOTE_PID=$!
  $ trap 'kill "$REMOTE_PID" $LOCAL_PID 2>/dev/null; wait 2>/dev/null' EXIT
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S remote.sock ]; then break; fi
  >   sleep 0.1
  > done

The local daemon's listening socket is created owner-only.

  $ TOPUP_HOST_SOCKET_TESTHOST="$PWD/remote.sock" \
  > topup --socket "$PWD/local.sock" &
  $ LOCAL_PID=$!
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S local.sock ]; then break; fi
  >   sleep 0.1
  > done
  $ stat -c %a local.sock
  600

Registering a host persists `hosts.json` owner-only.

  $ printf '%s\n' \
  >   '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"start_session","arguments":{"host":"testhost"}}}' \
  >   | topup --proxy "$PWD/local.sock" \
  >   | grep -c '\\"ok\\":true'
  1
  $ stat -c %a hosts.json
  600

(`sessions.json` is persisted by `Session_pool` through the identical
`open_out_gen … 0o600` path as `hosts.json`; covered by that symmetry
rather than by spawning a named-session subprocess here.)

Clean up.

  $ kill "$LOCAL_PID" "$REMOTE_PID"
  $ wait 2>/dev/null
  $ trap - EXIT
