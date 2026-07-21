# Dynamic Pricing — Ledger Rules Specification (prototype)

**Status:** working document, 2026-06-12 — to be validated with Polina/Will at the weekly.
**Scope:** the DP/DP ("two dynamic lanes") mechanism on the Dijkstra era, Praos-only first
(every block is treated as an RB; the EB/RB distinction arrives with the consensus phase).
**Sources:** `formal-ledger-specifications@polina/dynamic` (b4c535b6), `tiered-pricing`
mechanism-design doc, Giorgos' deck (2026-05-14), abstract-sim (`tiered-pricing@abstract-sim`).
**Design flow:** see [`DYNAMIC_PRICING_FLOW.md`](./DYNAMIC_PRICING_FLOW.md) for the tx + block lifecycle diagram.

---

## 0. Vocabulary

One term per concept. The codebase speaks the domain language; the spec column is for
traceability when reviewing against the Agda.

| Domain term (code) | Meaning | Spec (Agda) |
|---|---|---|
| `Inclusion` = `Urgent` \| `Optimistic` | The inclusion strategy a tx purchases (TxBody field: `dtbInclusion`) | `TierNo` (fast = 0, slow = 1) |
| `InclusionPrice` | An inclusion strategy's public price: lovelace per byte | `TierCoeff` / `coeffRange` |
| `InclusionPrices` | The pair of published prices, total by construction | `DiversityPolicy` |
| `Quote` | The fee (lovelace) demanded for one tx under one strategy | the `tierCoeff × minfee` premise |
| `bidFee` | The tx's fee field (Dijkstra: `dtbBidFee`), read as a price cap | `txFee` (spec reads it as exact fee) |
| `feeRefundAccount` | Where the overpayment goes back | `feeChangeAddr` |
| `InclusionUsage` / `blockUsage` | Per-strategy resource counters within one block | `totalSize/totalFees/totalExUnits` |
| `PricingState` | Published prices + usage, carried by `UTxOState` | `SDPolicy` |
| `reprice` / `endOfBlock` | End-of-block price update + counter reset | `updateTiers` / `DIVUP` |

Infrastructure note: *lanes* (RB vs EB transport) are a consensus / linear-Leios concern and never
appear in ledger vocabulary. `Urgent` / `Optimistic` are the declared inclusion strategies used for
pricing and usage accounting; RB/EB placement is transport. Current `leios-prototype` applies EB txs
later through certification, which is a linear-Leios apply-time property, not a tiered-pricing rule.

---

## 1. State extension — DONE (2026-06-12)

Implemented with the codebase's canonical era-family technique (the
`EraGov`/`CertState`/`InstantStake` pattern), NOT the direct concrete-field
extension:

```
-- cardano-ledger-core, Cardano.Ledger.DynamicPricing.State
class (Eq/Show/NFData/NoThunks/EncCBOR/DecCBOR/Default/ToJSON (PricingState era))
   => EraPricing era where
  type PricingState era = (r :: Type) | r -> era
  emptyPricing :: PricingState era

-- Shelley UTxOState gains ONE family-typed field:
utxosPricing :: !(PricingState era)
```

Per-era instances: `NoPricing` (inert unit) for Shelley→Conway;
`DynamicPricing` (published `InclusionPrices` + per-block `InclusionUsage`
counters) for Dijkstra — activated by the Conway→Dijkstra translation with
`initialPricingState` (`Optimistic` at today's `minFeeA` 44 lovelace/byte,
`Urgent` at 2× — the CIP's initial coefficient; no cross-lane floor since 2026-07-20). Pre-Dijkstra wire format only gains one constant byte.

`feeRewards` (pending refunds) will live INSIDE `DynamicPricing` when the fee
split lands (rule 3) — the family makes a second cross-era field unnecessary.

Pragmatic shortcut, documented: `EraPricing` was added as a superclass of
`EraGov`, so every existing `EraGov era` constraint provides it for free —
this is what kept the constraint cascade contained. To revisit if upstreaming.

The whole domain now lives in `cardano-ledger-core:Cardano.Ledger.DynamicPricing.*`
(it only depends on core, and shelley cannot depend on dijkstra). The DDD split is:
`InclusionStrategy` (purchased strategy), `Pricing` (prices/quotes), `Usage` (per-block counters),
`Refunds` (pending fee refunds), `Controller`/`Repricing` (end-of-block price publication), and
`State` as the era-indexed aggregate.

---

## 2. UTXO rule — judging the bid (per transaction) — DONE (2026-06-12)

For a transaction `tx` declaring inclusion strategy `i`, against the current published prices `P`:

**Premise U1 — the bid covers the quote.**

```
quoteFor pp tx (priceOf (chargedStrategy i delivery) P) ≤ tx.bidFee
───────────────────────────────────────────────────────  otherwise BidBelowQuote {expected, supplied}
```

**UPDATED (2026-07-21, the CIP's rb-only premium scope):** the applicable strategy follows
the block's **delivery**, not the declaration — `chargedStrategy Urgent Certified = Optimistic`:
an urgent transaction arriving through a certified endorser block pays the optimistic quote
(validity, premium and refund alike). The delivery (`Immediate` | `Certified`) is stamped on
the pricing state by the BBODY rule before the block's transactions run (a certificate-carrying
ranking block is payload-free, so a block's transactions all share one delivery) and reset at
the block boundary. The mempool's fee-cap basis becomes max-of-two for urgent bids (admission
one worst-case step ahead, re-validation at the current max), since an urgent transaction may
settle through either path. On a certified round, B1 bounds the block's TOTAL usage against
the EB budgets. **UPDATED (2026-07-21, riders on):** the endorser block is now the FIFO
ticket-merge of the urgent remainder and the optimistic lane, so urgent riders do arrive
through certified endorser blocks and settle at the optimistic quote. The consensus side
keeps this safe with the announced-EB mempool strip: as soon as a node stores an announced
endorser block's body, its transactions leave that node's mempool, so no later ranking block
carries one of them a second time (see `MEMPOOL_2LANE_DESIGN.md`, "EB Retention").

where `quoteFor pp tx price = max (minimumTxFee pp tx) (txFeeFixed + price × txSizeInBytes tx)`.
This *replaces* the era's plain min-fee premise (`minfee ≤ txFee`) — it degenerates to it
when `i = Optimistic` and the optimistic price sits at today's rate.
*(Spec: `tierCoeff × minfee ≤ txFee`. See open question Q2 on the fee base.)*

**Transformation U2 — usage accounting.** Every valid tx is recorded:

```
blockUsage' = recordTx i (txSizeInBytes tx) (chargedFee tx) (tx.exUnits) blockUsage
```

*(Spec: `processTxTiers`, counted by the declared strategy — unambiguous here since
`actualTier` is not modelled; see the decision under open question Q1b.)*

---

## 3. Fee split — DONE (2026-06-12, in the UTXO rule)

Let `quote` be the amount actually charged (the strategy's quote at inclusion), `base` the
protocol minimum fee, and `cap = tx.bidFee` the authorised maximum.

**When `feeRefundAccount = Just acct`:**

```
treasuryAmt = quote − base          -- the urgency premium    → treasury (donations)
refundAmt   = cap − quote           -- the unused headroom    → feeRewards(acct)
feePotAmt   = base? → 0 ⚠           -- the spec sends NOTHING to the fee pot
```

*(Spec, `Scripts-Yes` + `produced`: `trsAmt = (coeffR − 1) × base`, `fcAmt = txFee − trsAmt`,
fee pot +0. The fee pot starvation is deliberate in the spec but has SPO-rewards
implications — open question Q3.)*

**Value conservation.** The `consumed == produced` equation gains both new summands
(`treasuryAmt` via donations, `refundAmt` via the pending-refund map). Forgetting either
breaks every block.

**When `feeRefundAccount = Nothing`:** current behaviour, the full fee goes to the fee pot.

**As implemented** (in `dijkstraUtxoTransition`, after UTXOS settles with today's
semantics): when `dtbFeeRefundAccount` (CBOR key 28) is present, the pots are
redistributed — `base` (the protocol minimum) STAYS in the fee pot (prototype answer to
Q3: SPOs keep today's revenue, deviating from the spec's fee-pot starvation),
`premium = quote − base` moves to the donation pot (treasury), and
`refund = bid − quote` is recorded as a pending refund, delivered by the LEDGER rule.
Value conservation is untouched: UTXOS checked it before the redistribution, which only
moves value between pots.

---

## 4. LEDGER rule — delivering the refund — DONE (2026-06-12)

After each valid tx, pending refunds are flushed into withdrawable rewards:

```
rewards'    = rewards ∪⁺ feeRewards     -- credited per stake credential
feeRewards' = ∅
```

*(Spec: `Ledger.lagda`. As implemented: `flushPendingRefunds` in the Dijkstra LEDGER
rule credits registered accounts via `addToBalanceAccounts`; refunds to UNREGISTERED
accounts stay pending — open point: should the UTXO rule reject a refund account that
is not registered?)*

---

## 5. BBODY rule — closing the block (DIVUP) — DONE (2026-06-12)

Runs **after** all the block's transactions are processed (it consumes the accumulated
`blockUsage`), chained as `… >> alonzoBbodyTransition >>= divupTransition`.

**Premise B1 — the optimistic usage fits the endorser block (EB)** (`sdChecks`).

The optimistic lane has its **own** block budget — the endorser block (EB) — distinct from the
RB the urgent lane fills. The EB budget is the real mainnet one: the CIP-164 closure-size limit
(`optimisticBlockCapacity = 12,000,000` bytes — an absolute budget, ~133× the RB, not a
protocol-parameter multiple). The ExUnits ceiling scales by how many RBs fit in that budget,
pending a real per-EB execution budget.

```
bytesUsed(Optimistic)   ≤ optimisticBlockCapacity
exUnitsUsed(Optimistic) ≤ (optimisticBlockCapacity / pp.maxBlockSize) · pp.maxBlockExUnits
─────────────────────────────────────────────────  otherwise OptimisticOverflowsBlock /
                                                    OptimisticOverflowsBlockExUnits
```

The RB stays bounded by the inherited block-body-size and `TooManyExUnits` (whole-block ExUnits)
checks. Praos-only nuance: every block is physically an RB, so `TooManyExUnits` (≤ 1× RB) is the
binding limit and the EB check is **dormant** — it becomes the EB's hard cap once optimistic txs
move to a separate endorser block in the consensus phase.

**Transformation B2 — republish the board and reset** (`endOfBlock`).

```
prices'     = reprice pricingState     -- per-lane EIP-1559 controller (Will), DONE 2026-06-17
blockUsage' = ∅
```

`reprice` now runs Will's per-lane EIP-1559 controller (mechanism-design doc,
`Cardano.Ledger.DynamicPricing.Controller.stepPrice`), one step per lane:

```
price' = price · (1 + clamp((u − target)/(target·D), −1/D, +1/D)),  floored at minFeeA
```

with the ledger calibration `defaultControllerParams` = the CIP's recommended construction
(`target = 1/2`, `D = 16` ⇒ at most ±6.25%/block; deterministic `Rational` arithmetic, lovelace
rounded). We ran `D = 4` (±25%) until 2026-07-13 and `D = 8` (±12.5%) until 2026-07-20 for a
livelier demo staircase; both `8` and `16` sit inside the CIP's validated envelope. The
utilisation signal is each lane's **own** fill against its **own** budget: `Urgent` ← urgent bytes
/ RB, `Optimistic` ← optimistic bytes / `optimisticBlockCapacity` (spec-aligned: Polina's
`regCap` = the per-EB cap). At realistic traffic the optimistic fill sits far below its target,
so that price rests at the floor — the mechanism's real behaviour, and exactly the regime
Giorgos's EB min-fill rule addresses. An urgent flood moves only the urgent price; the optimistic
price tracks optimistic demand alone. After both lanes step,
the cross-lane invariant is re-imposed structurally via `mkInclusionPrices`:

```
no cross-lane constraint — the lanes publish independently and may briefly cross
(the discrimination floor was removed 2026-07-20 to match the CIP; its experiments
rejected fixed floors)
```

**UPDATED (2026-07-21):** window smoothing is IMPLEMENTED per the CIP — each lane reads a
window of recent samples (`Signal.hs`: urgent 5 samples against the reservation capacity,
standard 20 capacity-weighted blocks; bytes AND ExUnits, larger ratio wins; both lanes step
every sample-carrying reprice, the hold rules are gone). Still deferred: making
`optimisticBlockCapacity` a protocol parameter (today a mainnet-calibrated constant), a real
per-EB ExUnits budget, the additive overflow-pricing term
(`overflow_linear_price_per_fill` in Will's winner), and whether `target`/`D` become
protocol parameters.

**Temporal semantics.** The prices published at the end of block *N* are what the UTXO
rule (and the mempool) judge the transactions of block *N+1* against.

---

## 6. New predicate failures

| Failure | Rule | Trigger |
|---|---|---|
| `BidBelowQuote` | UTXO | fee cap below the current quote for the declared level |
| `OptimisticOverflowsBlock` | BBODY | optimistic byte usage exceeds the EB byte budget (`optimisticBlockCapacity`, 12 MB) |
| `OptimisticOverflowsBlockExUnits` | BBODY | optimistic ExUnits usage exceeds the EB ExUnits budget (scaled from `optimisticBlockCapacity`) |

---

## 7. Open design questions (tracked for the weekly)

1. ~~Declared quote or not?~~ **DECIDED (2026-06-12): no declared quote.** The bid is
   fully described by `dtbInclusion` + `dtbBidFee` (max-fee + refund semantics); the
   spec's declared `tierCoeff` and its strict-equality `checkPolicyState` are not
   implemented. To revisit only if the `HonourSubmissionQuote` fee semantics survives
   Will's sweeps — divergence from the spec to present to Polina.
1b. ~~Promotion / `actualTier`?~~ **DECIDED (2026-06-12): not modelled.** The spec's
   `actualTier` ("the tier the tx is actually placed in") is lane vocabulary: what the
   producer chooses is the *placement* (RB vs EB) — consensus infrastructure — not the
   inclusion strategy, which is a contract fixed at purchase. In the current v1 consensus
   plan, Urgent txs are RB-only because certified EB txs apply later. Charging and usage
   accounting are always by the DECLARED strategy. This also dissolves the spec's
   `processTxTiers`-vs-fee-split
   inconsistency (counting by declared, charging by actual) and the redundant
   `coeffR ≥ tierCoeff` premise (already structurally guaranteed by the discrimination floor).
   Divergence from the spec to present to Polina.

2. **Which resources does urgency reprice?** Sim: bytes only (per-byte rate, floored at the
   full min fee). Spec: the full min fee including script costs. Tension: ExUnits feed the
   congestion signal but are not repriced under the sim variant.
3. **Fee pot starvation.** Under the split, the fee pot receives nothing from refunding
   txs — what is the long-term SPO incentive story?
4. **The `reprice` formula.** ~~`updateTiers = id`.~~ **IMPLEMENTED (2026-06-17):** Will's
   per-lane EIP-1559 controller (`stepPrice`), calibrated to the CIP's recommendation (`target = 1/2`,
   `D = 16` since 2026-07-20). **UPDATED (2026-06-25):** the optimistic lane prices on its **own fill**, so an
   urgent flood no longer moves the optimistic price — two genuinely dynamic, independent lanes.
   **UPDATED (2026-07-06):** the optimistic budget is now the real mainnet EB capacity
   (`optimisticBlockCapacity` = 12 MB, the CIP-164 closure-size limit) for BOTH the pricing
   target and the B1 overflow hard cap (the EIP-1559 limit-vs-target split, spec-aligned with
   Polina's per-EB `regCap`). Consequence: at demo traffic the optimistic price rests at the
   floor — the real regime, the one Giorgos's EB min-fill rule addresses. Window smoothing
   landed 2026-07-21 (the CIP's 5/20 windows). Still open: the additive overflow term, a real
   per-EB ExUnits budget, and whether the knobs become protocol parameters.
5. **Linear-Leios cert/txs exclusivity, not DP pricing.** Current `leios-prototype` already makes a
   certifying Dijkstra block carry no RB txs on the wire; `resolveLeiosBlock` later substitutes the
   certified EB tx sequence for ledger application. Whether linear-Leios should allow "cert + inline
   txs" again is a consensus representation/apply-time decision. DP should only depend on the declared
   inclusion strategy for charging and usage.

---

## 8. Where each piece lands (PR plan)

| Piece | File(s) | PR |
|---|---|---|
| `Inclusion` on `TxBody` (done), `feeRefundAccount` (next) | `Dijkstra/TxBody.hs`, `DynamicPricing.hs` | 1 |
| U1 (+ U2 if kept) | `Dijkstra/Rules/Utxo.hs` | 2 |
| State extension + board genesis + U4 | `Shelley/LedgerState/Types.hs`, `Dijkstra/Rules/Utxo.hs` | 3 |
| Fee split + conservation + LEDGER flush | `Dijkstra/Rules/Utxos.hs`, Conway `produced`, `Dijkstra/Rules/Ledger.hs` | 4 |
| B1 + B2 (`divupTransition`) | `Dijkstra/Rules/Bbody.hs` | 5 |
| `blockType`, `placementLane`, U3, EB path | consensus coordination | 6 |

### B2 refinement (2026-07-09, Nicolas's rule): each lane reprices on ITS OWN block's verdict (SYMMETRIC, both lanes)

The ranking block (urgent) and a certified endorser block (optimistic) are
applied in **separate** reprices: a ranking-block reprice carries urgent bytes
and zero optimistic; a certification reprice carries the endorser block's
optimistic bytes and **zero urgent** (measured live via a ledger probe). So each
lane must only move on a reprice that carries ITS OWN transport's bytes:

- **Urgent** holds on a pure certification reprice (zero urgent bytes, optimistic
  bytes present); it steps on ranking-block reprices — a full RB raises the
  price, a genuinely empty RB (both lanes zero, no urgent demand) decays it.
- **Optimistic** holds on ranking-block and idle reprices (zero optimistic
  bytes); it steps only when its endorser block counts (Giorgos's rule).

Without the urgent half, every certification was read as "the urgent lane ran
empty" and dropped the urgent price a full step between full blocks — the sawtooth seen
under saturation, the exact mirror of the optimistic ping-pong. With both halves,
each lane climbs a clean staircase under a full pool.

The urgent lane is judged every block (a regular block comes every round — an empty one really
means an idle lane). The optimistic lane is judged **only when one of its endorser blocks
actually counts in the block** (its certificate landed and its bytes applied): full EB counted
→ full upward steps that COMPOUND; light EB counted → a downward step; **no EB counted → the price holds**.
Rationale, measured live: certification pacing leaves most rounds with no optimistic block to
judge, and treating those as "the lane ran empty" made the price ping-pong floor ↔ floor×1.25
while the pool sat completely full — the price never rationed the overload. With
reprice-on-application, a full pool ⇒ full EBs published ⇒ a rising staircase; a light trickle
still publishes small EBs and decays the price to the floor; only a lane with zero applications
freezes its price (no buyers — the first application unfreezes it).

