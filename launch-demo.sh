#!/usr/bin/env bash
# One-command launch: build the node and the lane feeder (the first build is
# long), then boot the 3-node devnet and the dashboard on localhost:8780.
# Exactly the README's quickstart, in one script. Ctrl-C tears everything down.
set -euo pipefail
cd "$(dirname "$0")"; ROOT="$PWD"

cd cardano-node
nix develop --command cabal build exe:cardano-node exe:dijkstra-lane-feeder
NODE_BIN_DIR=$(dirname "$(nix develop --command cabal list-bin exe:cardano-node)")
FEEDER_BIN=$(nix develop --command cabal list-bin exe:dijkstra-lane-feeder)

cd "$ROOT/ouroboros-leios/demo/proto-devnet"
PATH="$NODE_BIN_DIR:$PATH" \
LANE_FEEDER="$FEEDER_BIN" \
DEMO_DIR="$ROOT/demo" \
exec bash run-dijkstra-live-demo.sh
