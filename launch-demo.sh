#!/usr/bin/env bash
# One-command launch: build the node and the lane feeder (the first build is
# long), then boot the 3-node devnet and the dashboard on localhost:8780.
# Exactly the README's quickstart, in one script. Ctrl-C tears everything down.
set -euo pipefail

# launchd defaults to 256 descriptors on macOS. The feeder opens many short
# local submission connections, so that limit makes node1 restart under load.
if [ "$(ulimit -n)" -lt 65536 ]; then
  ulimit -n 65536
fi

cd "$(dirname "$0")"; ROOT="$PWD"
WORKING_DIR="${WORKING_DIR:-${TMPDIR:-/tmp}/dijkstra-live-demo}"

# The dashboard calls this same script for a full restart. Serialize the short
# hand-off so repeated clicks cannot race, then stop the current supervisor
# before rebuilding or replacing its working directory.
RESTART_LOCK="${WORKING_DIR}.restart"
if ! mkdir "$RESTART_LOCK" 2>/dev/null; then
  owner=$(cat "$RESTART_LOCK/pid" 2>/dev/null || true)
  if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
    echo "A live-demo restart is already in progress (PID $owner)."
    exit 0
  fi
  rm -rf "$RESTART_LOCK"
  mkdir "$RESTART_LOCK"
fi
printf '%s\n' "$$" >"$RESTART_LOCK/pid"
release_restart_lock() {
  owner=$(cat "$RESTART_LOCK/pid" 2>/dev/null || true)
  [ "$owner" = "$$" ] && rm -rf "$RESTART_LOCK"
}
trap release_restart_lock EXIT

INSTANCE_LOCK="${WORKING_DIR}.instance"
old_pid=$(cat "$INSTANCE_LOCK/pid" 2>/dev/null || true)
if [[ "$old_pid" =~ ^[0-9]+$ ]] && [ "$old_pid" -ne "$$" ] && kill -0 "$old_pid" 2>/dev/null; then
  kill -TERM "$old_pid" 2>/dev/null || true
  for _ in $(seq 1 30); do
    kill -0 "$old_pid" 2>/dev/null || break
    sleep 1
  done
fi

for port in 3001 3002 3003 8780 8781; do
  lsof -ti tcp:"$port" 2>/dev/null | xargs kill 2>/dev/null || true
done
sleep 2
rm -rf "$WORKING_DIR"

cd cardano-node
DEV_SHELL="path:$ROOT?dir=cardano-node"
nix develop "$DEV_SHELL" --command cabal build exe:cardano-node exe:cardano-cli exe:dijkstra-lane-feeder
NODE_BIN_DIR=$(dirname "$(nix develop "$DEV_SHELL" --command cabal list-bin exe:cardano-node)")
CLI_BIN_DIR=$(dirname "$(nix develop "$DEV_SHELL" --command cabal list-bin exe:cardano-cli)")
FEEDER_BIN=$(nix develop "$DEV_SHELL" --command cabal list-bin exe:dijkstra-lane-feeder)

cd "$ROOT/ouroboros-leios/demo/proto-devnet"
release_restart_lock
trap - EXIT
exec nix shell nixpkgs#process-compose nixpkgs#yq-go --command env \
  DEMO_NODE_BIN_DIR="$NODE_BIN_DIR" \
  DEMO_CLI_BIN_DIR="$CLI_BIN_DIR" \
  LANE_FEEDER="$FEEDER_BIN" \
  DEMO_DIR="$ROOT/demo" \
  DEMO_LAUNCHER="$ROOT/launch-demo.sh" \
  WORKING_DIR="$WORKING_DIR" \
  bash -c 'export PATH="$DEMO_NODE_BIN_DIR:$DEMO_CLI_BIN_DIR:$PATH"; exec bash run-dijkstra-live-demo.sh'
