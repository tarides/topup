End-to-end coverage of checkpoint / restore over the Unix socket
transport. The phrase log is the source of truth; checkpoint copies
it, restore replaces it.

Set up sandboxed log, checkpoint, and spill directories so the
fixture is hermetic.

  $ TOPUP_LOG="$PWD/history.ml" \
  > TOPUP_CHECKPOINT_DIR="$PWD/ckpt" \
  > TOPUP_SPILL_DIR="$PWD/spill" \
  > topup --socket "$PWD/topup.sock" &
  $ SERVER_PID=$!
  $ trap 'kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null' EXIT
  $ for _ in 1 2 3 4 5 6 7 8 9 10; do
  >   if [ -S topup.sock ]; then break; fi
  >   sleep 0.1
  > done

Define a binding, snapshot the session under `pre`, then clobber it.

  $ ./socket_client.bc.exe topup.sock eval "let answer = 42;;"
  42
  $ ./socket_client.bc.exe topup.sock checkpoint pre
  ok
  $ ./socket_client.bc.exe topup.sock eval "let answer = 0;;"
  0
  $ ./socket_client.bc.exe topup.sock eval "answer;;"
  0

Restore replays the snapshot and brings the original binding back.

  $ ./socket_client.bc.exe topup.sock restore pre
  ok
  $ ./socket_client.bc.exe topup.sock eval "answer;;"
  42

Bindings evaluated after restore extend the log alongside the
restored phrases.

  $ ./socket_client.bc.exe topup.sock eval "let after = answer + 1;;"
  43
  $ ./socket_client.bc.exe topup.sock checkpoint post
  ok

Restoring a missing label surfaces an error without changing state.

  $ ./socket_client.bc.exe topup.sock restore no-such
  ERROR: no such checkpoint: no-such
  $ ./socket_client.bc.exe topup.sock eval "after;;"
  43

Both checkpoints are present on disk under the configured directory.

  $ ls ckpt | sort
  post.ml
  pre.ml

Shutdown unlinks the socket file.

  $ kill "$SERVER_PID"
  $ wait "$SERVER_PID" 2>/dev/null
  $ trap - EXIT
  $ [ -e topup.sock ] && echo "leak" || echo ok
  ok
