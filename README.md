# Two-lane dynamic pricing — all changes, one place

This super-repo **points to every repo that carries the two-lane dynamic-pricing
work** (Cardano **Dijkstra** era, leios prototype). Each entry below is a git
**submodule** pinned to the exact commit of my changes on my fork, so cloning
this one repo gives you the whole cross-repo change set.

```bash
git clone --recursive git@github.com:nhenin/dynamic-pricing.git
# or, after a plain clone:
git submodule update --init --recursive
```

## The repos & their changes

Each **compare** link is the native GitHub review view (diff + line comments) of
my `nicolas/dynamic-pricing` branch versus its upstream base.

| Repo (submodule) | Fork | What changed | Compare |
|---|---|---|---|
| `cardano-ledger` | [nhenin/cardano-ledger-specs](https://github.com/nhenin/cardano-ledger-specs) | 5 UTXO/BBODY rules + EIP-1559 reprice controller | [diff](https://github.com/nhenin/cardano-ledger-specs/compare/leios-prototype...nicolas/dynamic-pricing) |
| `ouroboros-consensus` | [nhenin/ouroboros-consensus](https://github.com/nhenin/ouroboros-consensus) | two-lane mempool, re-validation / eviction on price-rise | [diff](https://github.com/nhenin/ouroboros-consensus/compare/leios-prototype...nicolas/dynamic-pricing) |
| `cardano-node` | [nhenin/cardano-node](https://github.com/nhenin/cardano-node) | lane feeder + forge lane/price/queue traces | [diff](https://github.com/nhenin/cardano-node/compare/leios-prototype...nicolas/dynamic-pricing) |
| `cardano-api` | [nhenin/cardano-api](https://github.com/nhenin/cardano-api) | Dijkstra tx-body fields (inclusion / bid / refund) | [diff](https://github.com/nhenin/cardano-api/compare/leios-prototype...nicolas/dynamic-pricing) |
| `cardano-cli` | [nhenin/cardano-cli-dp](https://github.com/nhenin/cardano-cli-dp) | Dijkstra tx-body CLI support | [diff](https://github.com/nhenin/cardano-cli-dp/compare/leios-prototype...nicolas/dynamic-pricing) |
| `ouroboros-leios` | [nhenin/ouroboros-leios-dp](https://github.com/nhenin/ouroboros-leios-dp) | proto-devnet live-demo scripts + tailer | [diff](https://github.com/nhenin/ouroboros-leios-dp/compare/main...nicolas/dynamic-pricing) |

_`ouroboros-network` had no substantive change and is omitted._

## Status

- **Ledger — done.** 5 rules + reprice controller, builds `-Werror`, unit-tested.
- **Mempool — eviction on price-rise works.** Re-validation was made full
  (`reapplyShelleyTx`) so a risen quote re-checks U1 and drops the underpriced
  backlog. Verified live: ~220 txs mass-evicted per quote spike, 1728 over one run.
  Remaining gap: the `Mempool.RemoveTxs` trace isn't emitted (observability only).
- **Demo — working.** Real 3-node proto-devnet with live real prices.

