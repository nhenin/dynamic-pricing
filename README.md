# Two-lane dynamic pricing on Cardano — prototype & live demo

A working prototype of **dynamic, two-lane transaction pricing** for Cardano
(**Dijkstra** era, on top of the **Linear Leios** consensus prototype), with a
live 3-node network and a dashboard to drive it. This super-repo pins every
repo that carries the work, plus the demo dashboard and the design docs — one
clone gives you the whole thing.

```bash
git clone --recursive git@github.com:nhenin/dynamic-pricing.git
# or, after a plain clone:
git submodule update --init --recursive
```

## The walkthrough (8 min)

https://github.com/user-attachments/assets/6b3e4181-4610-4541-baa8-711e605c2614

The two lanes live on the devnet: rush hour, a price squeeze with real
evictions, the measured pots, a certification miss and its heal, the quiet
end. Captions included. The file also ships in the repo:
[demo/demo-walkthrough.mp4](demo/demo-walkthrough.mp4).

## The idea in one minute

Every Linear Leios block round carries **two block bodies**:

- a small **ranking block** (RB, 90,112 bytes) applied to the ledger instantly;
- a big **endorser block** (EB, 3,000,000 bytes — mainnet's CIP-164 closure
  THROUGHPUT at the demo's 4× block cadence: 12 MB per 20-second round there
  is 3 MB per 5-second round here, ~33× the RB) applied only once a committee
  certifies it.

Dynamic pricing turns those two transports into **two priced lanes**:

- **Urgent (fast lane → RB):** for time-sensitive traffic. Scarce space, so
  its price does the moving.
- **Optimistic (patient lane → EB):** for traffic that can wait a round or
  two. Huge space, so at realistic traffic its price rests at the floor.

A transaction **buys a lane**: it declares its inclusion strategy and bids a
fee cap. Its full price is `base fee + rate × size`, where the per-byte
**rate is republished by the ledger after every block**:

```
quote_next = max( floor, round( quote × (1 + swing) ) )
swing      = (fullness − target) / (target × D)
```

- **fullness** = the lane's usage over a **window** of recent rounds (5
  samples fast lane / 20 patient — the CIP's signals), each against its
  *own* budget, in bytes and ex-units (the larger ratio wins)
- **target** = ½ (the controller aims for half-full blocks — the other half is
  its price-signal headroom, not free space)
- **floor** = 44 lovelace/byte · **D** = 16, so a step is at most ±6.25 % per
  block (the CIP's recommended calibration)
- the lanes are priced **independently** — no cross-lane floor, so the two
  quotes may briefly cross (a permitted state; the urgent lane opens at 2×
  the floor and earns its premium from demand, not from a rule)

The rest of the mechanism, in the same spirit:

- **Bids are caps, prices move.** Admission demands one worst-case controller
  step of headroom (bid ≥ next-block quote), so a transaction that cannot
  survive a single adverse update is refused at the door. A waiting
  transaction whose bid falls below the climbing quote is **evicted**
  (re-checked O(1) at every new block).
- **Min-fill rule:** an endorser block is only issued when it carries at least
  **half a ranking block** (45,056 bytes) — below that the patient lane
  *pools* for the next round. One escape: after **10 rounds** without an
  endorser-block announcement, a below-threshold block may issue anyway, so a
  light trickle never pools forever.
- **First-come conflicts:** if two transactions of different lanes want the
  same coin, the one admitted first keeps it — an admitted transaction is
  never displaced.
- **Per-lane pools:** each lane has its own admission ceilings (bytes *and* an
  expected-diffusion-time budget), each pool ~200 MB deep. Since the lanes'
  FIFO merge, the announced endorser block still drains the urgent pool every
  round — depth costs wait, not correctness — and a storm queues and REPRICES
  instead of bouncing at the door. Only past the ceilings are senders held
  back — visible on the dashboard.

Full specifications: [docs/DYNAMIC_PRICING_LEDGER_RULES.md](docs/DYNAMIC_PRICING_LEDGER_RULES.md)
(the five ledger rules + the controller) and
[docs/MEMPOOL_2LANE_DESIGN.md](docs/MEMPOOL_2LANE_DESIGN.md) (the two-lane
mempool). Transaction/block lifecycle diagram:
[docs/DYNAMIC_PRICING_FLOW.md](docs/DYNAMIC_PRICING_FLOW.md).

## What's in the box

Each **diff** link is the native GitHub review view (full change set + line
comments) of the `nicolas/dynamic-pricing` branch versus its upstream base.

| Piece | What it carries | Diff |
|---|---|---|
| [`cardano-ledger`](https://github.com/nhenin/cardano-ledger-specs) (submodule) | The mechanism itself: pricing state, Dijkstra tx-body fields (inclusion / bid / refund account), the UTXO `BidBelowQuote` rule, usage accounting, the DIVUP block-close rule and the per-lane EIP-1559 controller | [diff](https://github.com/nhenin/cardano-ledger-specs/compare/leios-prototype...nicolas/dynamic-pricing) |
| [`ouroboros-consensus`](https://github.com/nhenin/ouroboros-consensus) (submodule) | The two-lane mempool: per-lane admission (bytes + diffusion-time), O(1) urgent admission, eviction-on-price-rise, first-come conflicts, forge selection with the min-fill rule, pool observability | [diff](https://github.com/nhenin/ouroboros-consensus/compare/leios-prototype...nicolas/dynamic-pricing) |
| [`cardano-node`](https://github.com/nhenin/cardano-node) (submodule) | The lane feeder (a crowd of simulated senders choosing lanes against live prices), forge lane/price/queue traces, demo controls (per-lane queue flush) | [diff](https://github.com/nhenin/cardano-node/compare/leios-prototype...nicolas/dynamic-pricing) |
| [`cardano-api`](https://github.com/nhenin/cardano-api) (submodule) | Dijkstra tx-body support for the new fields | [diff](https://github.com/nhenin/cardano-api/compare/leios-prototype...nicolas/dynamic-pricing) |
| [`cardano-cli`](https://github.com/nhenin/cardano-cli-dp) (submodule) | Dijkstra tx-body CLI support | [diff](https://github.com/nhenin/cardano-cli-dp/compare/leios-prototype...nicolas/dynamic-pricing) |
| [`ouroboros-leios`](https://github.com/nhenin/ouroboros-leios-dp) (submodule) | The 3-node proto-devnet, the run supervisor, the trace tailer and the demo web server | [diff](https://github.com/nhenin/ouroboros-leios-dp/compare/main...nicolas/dynamic-pricing) |
| [`demo/index.html`](demo/index.html) | The dashboard (a single self-contained page) | — |
| [`docs/`](docs/) | The design docs: ledger rules, two-lane mempool, lifecycle diagram | — |

## Running the demo

Prerequisites: **nix** (with flakes), ~16 GB RAM, macOS or Linux.

```bash
# 1. Build the node and the lane feeder (one cabal project; first build is long)
cd cardano-node
nix develop --command cabal build exe:cardano-node exe:dijkstra-lane-feeder

# 2. Point the run script at the binaries and the dashboard, then launch
NODE_BIN_DIR=$(dirname $(nix develop --command cabal list-bin exe:cardano-node))
FEEDER_BIN=$(nix develop --command cabal list-bin exe:dijkstra-lane-feeder)
cd ../ouroboros-leios/demo/proto-devnet
PATH="$NODE_BIN_DIR:$PATH" \
LANE_FEEDER="$FEEDER_BIN" \
DEMO_DIR="$(git rev-parse --show-toplevel)/../demo" \
bash run-dijkstra-live-demo.sh
```

The script boots a **real 3-node Dijkstra devnet**, the crowd feeder, the
trace tailer and two web servers, then streams every forged block into the
dashboard:

- **Presenter (drives everything): <http://localhost:8780>**
- **Audience copy (read-only, share this one): <http://localhost:8781>** — to
  put it on the internet for a call: `cloudflared tunnel --url
  http://localhost:8781` (viewers see the live network; only the presenter's
  port accepts commands).

`Ctrl-C` tears everything down. A fresh boot takes ~3 minutes (chain starts at
block 0).

### Driving it

Everything is on the page, in plain language, but the short tour:

- **👥 The crowd** — one click picks a complete crowd (who sends, how fast,
  which lanes): `Calm day`, `Rush hour`, `Urgent storm`, `Optimistic storm`
  (fat 12 KB payloads), `Ghost town`… The 🧾 journal tracks what became of
  every generation's transactions (sent → waiting → forged/dropped).
- **⚡ The pressure** — trouble on demand, on top of the crowd: `Price
  squeeze` (a burst bidding just above today's price — watch the climbing
  quote drop its own transactions, with the ledger's per-transaction verdict
  in the journal), `Coin clash` (first-come conflicts), `Certification miss`
  (the committee goes silent and the patient lane freezes).
- **Live cards** — each lane's published price (₳/KB and lovelace/byte), what
  its mempool holds and how many blocks that fills, its pool against both
  admission ceilings, and the wait a transaction sent *now* would face.
- **🚿 Flush a queue / 🔄 Restart the network** — presenter-only resets: drop
  one lane's waiting transactions (no restart), or reboot the whole network
  to a fresh chain from the page.

## What's real, what's simulated

- **Ledger** — the five rules + the controller, `-Werror`-clean, unit-tested.
- **Mempool** — per-lane admission, O(1) urgent ingress (measured 446 tx/s),
  exact eviction-on-price-rise (traced per transaction), the min-fill rule —
  all verified on the live network.
- **Simulated piece** — the endorser-block *certificate*: the committee's
  votes are cast and counted by the prototype itself (that is what the
  Certification-miss scenario switches off). Everything else on screen —
  prices, queues, blocks, evictions — is the real ledger and the real mempool.
- **Demo calibrations** — a block every ~5 s (activeSlotsCoeff 0.2, so
  certificates land in seconds instead of waiting out the leadership
  lottery); diffusion-time budget 60 s split 1/4 urgent / 3/4 patient; each
  pool ~200 MB deep, so a storm queues and REPRICES instead of bouncing at
  the door. All are parameters, not constants.

## How this maps to the CIP

This prototype backs the [Transaction Urgency Signalling CIP](https://github.com/input-output-hk/tiered-pricing/blob/main/docs/phase-2/CIP-urgency-signalling/README.md).
The dashboard speaks the CIP's vocabulary (standard lane, max fee,
announcement threshold). The code keeps its original internal names — the
mapping, for anyone reading the diffs:

| The CIP (and the dashboard) say | The code says |
|---|---|
| standard lane | `Optimistic` (inclusion strategy), the patient lane |
| max fee | `bidFee`, fee cap |
| EB announcement threshold | min-fill rule |

The prototype runs the CIP's recommended construction: target utilisation
0.5, max-change denominator 16, no cross-lane floor (crossings permitted),
urgent opening coefficient 2×, the 5-sample and 20-block signal windows,
admission one worst-case controller step ahead, the 45,056-byte
announcement threshold, and the K = 10 announcement age escape.

- **Premium scope (rb-only), live:** the ledger settles by DELIVERY: an
  urgent tx included through a certified EB is charged the standard quote
  (excess refunded), and every fee cap is the max of the two quotes. The
  EB is the FIFO merge of both lanes, so urgent overflow rides the
  endorser block. What keeps that safe: as soon as a node stores an
  announced EB's body, those txs leave its mempool — so no later ranking
  block carries one of them twice. Verified on the live network:
  thousands of riders per EB, identical strip counts on all three nodes,
  certificates applying round after round.

One simplification remains — the certificates (see *What's real, what's
simulated*). It does not touch what the prototype demonstrates: the lane
rules, the repricing and the settlement running in the real ledger and
node.
