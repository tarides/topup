Argv parsing and socket-file lifecycle.

Bad invocations exit 2 with a usage line.

  $ topup --bogus
  usage: topup-mcp [--socket <path>]
  [2]
  $ topup --socket
  usage: topup-mcp [--socket <path>]
  [2]

Boot a daemon and confirm the socket is bound.

  $ TOPUP_LOG=off TOPUP_SPILL_DIR="$PWD/spill" topup --socket "$PWD/topup.sock" &
  $ SERVER_PID=$!
  $ trap 'kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null' EXIT
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S topup.sock ]; then break; fi
  >   sleep 0.1
  > done
  $ [ -S topup.sock ] && echo bound || echo missing
  bound

A second daemon on the same path is refused with exit 1.

  $ TOPUP_LOG=off TOPUP_SPILL_DIR="$PWD/spill2" topup --socket "$PWD/topup.sock"
  topup-mcp: socket $TESTCASE_ROOT/topup.sock is in use by another process
  [1]

Shutting the daemon down via SIGTERM unlinks the socket.

  $ kill "$SERVER_PID"
  $ wait "$SERVER_PID" 2>/dev/null
  $ [ -e topup.sock ] && echo leak || echo cleaned
  cleaned

A stale path (here: an ordinary file left behind) does not block a
fresh daemon — it is unlinked and rebound.

  $ touch topup.sock
  $ [ -f topup.sock ] && [ ! -S topup.sock ] && echo "stale file present" || echo "wrong setup"
  stale file present
  $ TOPUP_LOG=off TOPUP_SPILL_DIR="$PWD/spill3" topup --socket "$PWD/topup.sock" &
  $ SERVER_PID=$!
  $ trap 'kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null' EXIT
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S topup.sock ]; then break; fi
  >   sleep 0.1
  > done
  $ [ -S topup.sock ] && echo "bound over stale file" || echo "still a plain file"
  bound over stale file
  $ kill "$SERVER_PID"
  $ wait "$SERVER_PID" 2>/dev/null
  $ trap - EXIT
