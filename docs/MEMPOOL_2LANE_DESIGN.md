# Two-lane mempool — implementation design (physical lanes)

**Decision (2026-06-17):** go with **two physical lanes** in the mempool now (Urgent / Optimistic),
optimize later.
**Update (2026-06-23):** the two lanes are **not independent**. The mempool has a global ledger order:
all Urgent txs are applied before all Optimistic txs.
**Decision (2026-06-23):** on current `leios-prototype`, Urgent txs are RB-only in v1. EB txs are
applied later, when certification lands, so putting Urgent txs in an EB does not provide urgent
ledger service. Urgent txs that do not fit the current RB stay in the mempool for a later RB.
Companion to `MEMPOOL_CONSENSUS_ANALYSIS.md` (code analysis) and `MEMPOOL_DESIGN.md`.
Target repo: `ouroboros-consensus` (+ `ouroboros-consensus-cardano` for the Dijkstra instance).
Base branch: `leios-prototype` (not `main` / `master`).

## Principle

- **A lane is derived from the tx**, not passed by the caller: `dtbInclusion = Urgent` routes to the
  urgent lane; `dtbInclusion = Optimistic` routes to the optimistic lane. (Cleaner than Polina's §12
  sketch, which makes the lane a caller arg.)
- **Lane maps to transport, one-to-one.** An Urgent tx is selected only for the RB; an Optimistic tx
  is selected only for the EB. There is **no RB filler**: an Optimistic tx never lands in the RB, even
  when the urgent lane leaves it half-empty. The tx always pays and is accounted by its declared
  `dtbInclusion`.
- **Global mempool apply order:**

  ```text
  tip -> urgent lane -> optimistic lane
  ```

  Inside the mempool, the last Urgent tx is always before the first Optimistic tx from the ledger's
  point of view. Current `leios-prototype` applies announced EB txs later, at certification time, so
  on-chain RB/EB ordering has an extra linear-Leios constraint; see "Linear-Leios apply-time
  constraint" below.
- **Extension point:** prefer adding lane classification to `TxLimits`, not `LedgerSupportsMempool`.
  The Shelley `LedgerSupportsMempool` instance is generic over all Shelley-based eras, while `TxLimits`
  already has an era-specific Dijkstra instance. Default: single effective lane for all non-Dijkstra
  blocks.

  ```haskell
  data MempoolLane = UrgentLane | OptimisticLane

  txInclusionLane :: GenTx blk -> MempoolLane
  txInclusionLane _ = UrgentLane
  ```

  The Dijkstra `TxLimits (ShelleyBlock p DijkstraEra)` instance reads `dtbInclusion`.

## Confirmed v1 Semantics

### Pricing and Usage

- `Urgent` txs always pay the Urgent quote and are selected only for RBs.
- `Optimistic` txs always pay the Optimistic quote and are selected only for EBs.
- Usage accounting follows the declared inclusion strategy.
- No `actualTier`, no lane-mismatch repricing/refund. Refund remains `bidFee - quoteFor(dtbInclusion)`.

### Conflict Rule

Urgent dominates Optimistic:

- If an Optimistic tx is already in the mempool and a later Urgent tx spends the same input, admit the
  Urgent if it is valid against the urgent lane, then revalidate the optimistic lane; the conflicting
  Optimistic drops.
- If an Urgent tx is already in the mempool and a later Optimistic tx spends the same input, the
  Optimistic fails admission because it is validated after the urgent lane.
- Within a lane, existing FIFO/ledger semantics apply.

### Capacities

Capacity is strict at admission, using the same policy as today's single-lane mempool: no eviction,
no replace-by-fee, caller waits/retries when space appears. The multipliers should become tunable
eventually; v1 constants:

```text
urgentCapacity     = 2 * rbCap
optimisticCapacity = 2 * ebCap
```

Rationale: Urgent service is RB-only in v1; Optimistic service is sized to EB, with RB leftover treated
as opportunistic bonus capacity at forge time, not guaranteed admission capacity.

### EB Retention

**UPDATED (2026-07-21, the announced-EB mempool strip):** as soon as a node knows what an
announced EB carries (its body arrives — on the forger at forge time, elsewhere right after
the small body download), those txs leave its mempool (`LeiosMempoolStrip`, driven by the
same LeiosDb notifications as the voting loop). They are on their way on-chain through the
certification pipeline; keeping them selectable would let a later RB carry one of them a
second time — with riders in the EB (the CIP's FIFO merge, now on) the certified batch would
then replay a spent input and become unappliable on every node. The EB applies from the
closure in the LeiosDb, never from mempool copies, so certification does not need the txs
retained; and the prototype has no EB-abandonment path (one EB in flight, it stalls until
certified), so nothing is lost by stripping early. The old rule — keep txs until
certification lest an uncertified EB lose them — is superseded.

**UPDATED (2026-07-22, the readmission):** the strip alone made a missed
certification a permanent loss — a superseded EB's txs sat in no mempool any
more (observed live: ~half the EBs stranded under back-to-back announcements,
3,709 txs in one morning). The strip now carries its own inverse: when a new
announcement replaces one that never applied, the replaced EB's txs are
offered back to the mempool (decoded from the closure the node already
stores, `txFromLeiosBytes`). The mempool's own admission is the arbiter — a
block that did certify re-admits nothing (inputs already spent), a stranded
one re-enters and rides a later EB. A probe sample spread across the closure
keeps the certified-case cost bounded. A certification miss is a delay again,
not a loss.

**UPDATED (2026-07-22, the express reserve):** one regular block's worth of the
urgent remainder is held OUT of the merge (`selectForForge`): the next RB is
never empty while urgent traffic waits, and the held txs keep the instant
service they bid the premium for. Only the overflow beyond the reserve rides.
A selection-policy choice (the simulator's recommended construction merges the
whole remainder) — flagged to Will for review.

**UPDATED (2026-07-23, cert blocks apply their own payload FIRST):** the
reserve's children ride the endorser block while their parents wait for the
next RB — and when that next RB carries the certificate, apply-time used to
REPLACE its payload with the EB cargo, silently dropping the parents and
orphaning the children: an invalid block, a wedged chain (seen live at 250
tx/s). The resolve now PREPENDS the block's own payload to the cargo
(`resolveLeiosBlock`). The order is the dependency order: admission refuses
any child of an in-flight EB transaction, so the payload never depends on the
cargo, while the cargo may spend payload outputs. One consequence, flagged:
a certified round settles the block's own payload at the certified rate too
(the delivery stamp is per block, not per transaction).

## InternalState — two physical lanes, one chained ledger order

Today (`Impl/Common.hs:104`) `InternalState` has ONE `isTxs`, ONE `isLedgerState`, ONE `isCapacity`,
ONE `isLastTicketNo`. Two-lane version has separate transaction sequences and capacities, but the
cached ledger states are chained:

```text
baseState        = tip
urgentState      = baseState + urgentTxs
optimisticState  = urgentState + optimisticTxs
```

This is deliberately **not** two independent sub-mempools.

| field today | Urgent lane | Optimistic lane |
|---|---|---|
| `isTxs` | `isUrgentTxs` | `isOptimisticTxs` |
| `isLedgerState` | `isUrgentLedgerState = tip + urgentTxs` | `isOptimisticLedgerState = urgentState + optimisticTxs` |
| `isCapacity` | `2 * rbCap` | `2 * ebCap` |
| `isLastTicketNo` | Prefer one global counter, or per-lane if API churn is lower | Prefer one global counter, or per-lane if API churn is lower |
| keys/values cache | per lane | per lane |

Keep a global tx-id set even with two sequences, so duplicates are rejected across lanes and existing
`snapshotHasTx`/lookup semantics stay coherent.

## Operations

Reuse the existing `revalidateTxsFor` workhorse, but wire it in chained order.

- **Admission — Urgent** (`validateNewTransaction` :346 / `pureTryAddTx`):
  1. Check urgent capacity.
  2. Validate the Urgent tx against `isUrgentLedgerState`.
  3. Append to `isUrgentTxs`; advance `isUrgentLedgerState`.
  4. Immediately revalidate `isOptimisticTxs` against the new `isUrgentLedgerState`.
  5. Drop Optimistic txs invalidated by the new Urgent ordering and free optimistic capacity immediately.
- **Admission — Optimistic**:
  1. Check optimistic capacity.
  2. Validate against `isOptimisticLedgerState`.
  3. Append to `isOptimisticTxs`; advance `isOptimisticLedgerState`.
- **Sync on new tip** (`implSyncWithLedger` :517 / `revalidateTxsFor` :403):
  1. Revalidate urgent lane against the new ticked tip.
  2. Revalidate optimistic lane against the resulting urgent ledger state.
  3. `removedTxs` is the union of both invalidation sets.
  4. Dynamic-pricing eviction is free here: a repriced tx fails `reapplyTx` via `BidBelowQuote` and drops.
- **Manual removal**:
  - If removing urgent txs, revalidate optimistic after the new urgent state.
  - If removing only optimistic txs, revalidate optimistic only.
- **Capacity**:
  - Add helpers for per-lane mempool capacities.
  - `rbCap = blockCapacityTxMeasure`.
  - `ebCap = ebCapacityTxMeasure` when available; default no-EB for non-Leios.

## Snapshot and Forge Path

The forge path is a **clean lane-to-block partition**: each lane maps to exactly one block, no filler.

```text
RB:
  1. urgent prefix up to rbCap

EB:
  1. optimistic prefix up to ebCap
```

Selection is FIFO and **stop-on-first-blocker** per lane:

- If the next tx does not fit, stop scanning that lane.
- If the next tx unexpectedly fails validation in the snapshot, stop scanning that lane and keep it in
  the mempool. Do not skip it to include later txs.
- Forge-time selection does not evict; real removals happen through mempool revalidation/sync.

### Observability (implemented)

The forge path emits a per-block lane breakdown for devnet validation. `snapshotTakeForForge` returns a
`ForgeLaneSummary` (urgent in RB, optimistic in EB), computed by `summariseForgeSelection` in
`Mempool.Lanes`; `NodeKernel` traces it through the **existing** `leiosKernelTracer`
(`MkTraceLeiosKernel "forge lanes: …"`). This adds no new shared trace constructor, so it touches no
`cardano-node` tracing instances (those total pattern matches would otherwise all need updating). Cost
of the only host-signature change: `snapshotFromIS` gains `LedgerSupportsMempool blk` (zero-ripple —
every caller already carries it).

With the one-to-one lane→block mapping the summary is just each block's size: the RB is urgent-only, the
EB optimistic-only. No classifier is needed, and the old "Optimistic filler only when urgent is
exhausted" caveat is gone — an Optimistic tx is never placed in the RB.

A second trace, `forge prices: urgent=N, optimistic=M`, reports the current published inclusion quotes
(lovelace/byte) at each forge, via a new `TxLimits.forgePublishedPrices` accessor (default `Nothing`;
the Dijkstra instance reads `utxosPricing → publishedPrices`, HFC delegates to the active era). Same
`leiosKernelTracer`, no new shared trace constructor. It lets a devnet watch the EIP-1559 controller
move the quotes under load.

A third trace, `forge queue: urgent=P, optimistic=Q`, reports each lane's **queue depth** at forge time
— how many txs are still waiting in the lane after the size-bounded block selection. `selectForForge`
already holds the whole `MempoolLanes`, so the counts are the lane `TxSeq` lengths, carried on
`ForgeSelection`/`ForgeLaneSummary` and rendered by `renderForgeQueueSummary` (`Mempool.Lanes`), emitted
next to the lane trace in `NodeKernel`. Same `leiosKernelTracer`, no new shared trace constructor. The
backlog per lane is exactly what drives that lane's quote: a queue that builds pushes the price up, and
the price eases as it drains.

### Proto-devnet validation (e2e, 2026-06-26)

Validated end-to-end on the local `demo/proto-devnet` (macOS, `TC=0`, no sudo — the three nodes share
`127.0.0.1`) with the rebuilt local node. A single sustained Dijkstra-feeder run from the genesis funds
drives congestion (the devnet has only two genesis UTxOs, and the feeder spends them, so a separate
light phase cannot precede a heavy one — the heavy one then hits `AllInputsAreSpent`). Observed:

```text
forge lanes: RB urgent=7, EB optimistic=14                       # no filler: RB urgent-only / EB optimistic-only
forge prices: urgent=704, optimistic=44  ->  urgent=880, optimistic=55   # both quotes rise x1.25 under load
```

Both lanes' quotes rose under congestion and the 16x discrimination floor held (880 = 16 × 55), with no
`InvalidBlock` / `OptimisticOverflowsBlock` / `StoreButDontChange` signals.

Consistency fix surfaced here: the **forge's** EB byte capacity (`leiosEndorserBlockMeasure`, consensus)
must equal the **ledger's** optimistic EB budget (`optimisticBlockCapacity`, 12 MB), clamped to the
Leios EB closure-size transport limit. Otherwise the forge over-fills the EB and the ledger rejects it
with `OptimisticOverflowsBlock` → the EB never applies → the optimistic quote can never move. Aligning
the two is what let the optimistic lane respond.

The reproducible script is `repos/ouroboros-leios/demo/proto-devnet/run-dijkstra-lane-pressure.sh`;
operational details are in `organisation/06_prototype/CODEX_HANDOFF_2026-06-24.md`.

**Live demo (2026-06-29).** `run-dijkstra-live-demo.sh` runs the same devnet open-ended with two
continuous feeders (one per lane, on separate genesis UTxOs via the feeder's new `--fund-index`; the
feeder also gained `--delay-ms` pacing and resubmits on transient mempool backpressure instead of
dying). A tailer merges all three nodes' forge traces into `live.ndjson`, which the dashboard at
`organisation/06_prototype/demo/index.html` polls. Observed under sustained load: full blocks (RB
urgent=52, EB optimistic=104 ≈ 156 txs/block), per-lane queues building into the thousands, urgent
quote climbing 704 → ~1820 (₳ 1.86 per 1 KB tx) while the 16× floor held. Ctrl-C tears the whole thing
down. The per-lane queue depth is the new `forge queue:` trace above.

Ledger-order sketch:

```haskell
urgentForRb = takeValidFifo UrgentLane rbCap tipState
optimForEb  = takeValidFifo OptimisticLane ebCap (tipState + urgentForRb)

intendedMempoolOrder = urgentForRb ++ optimForEb
rbTxs                = urgentForRb   -- urgent only, no filler
ebTxs                = optimForEb    -- optimistic only
```

This preserves the intended mempool ordering:

```text
intended mempool order = selected urgent txs ++ selected optimistic txs
transport placement    = RB(urgent prefix), EB(optimistic prefix)
```

### Linear-Leios apply-time constraint

This is not tiered-pricing-specific; it is current `leios-prototype` behavior:

- A non-certifying Dijkstra block puts `fbRbTxs` in the block body.
- `fbEbTxs` are stored as an announced EB and are **not** applied in that RB.
- A later certifying Dijkstra block carries no RB txs on the wire; `resolveLeiosBlock` replaces the
  body tx sequence with the certified EB txs before ledger application.

Therefore the actual ledger application units are "RB txs now" or "certified EB txs later", not one
combined `rbTxs ++ ebTxs` block. The no-filler policy makes this safe by construction: the RB carries
only Urgent txs and the EB only Optimistic ones, so no Optimistic tx is ever applied before a pending
Urgent one. (This hazard is exactly why an RB filler would have had to be constrained — dropping the
filler removes it outright.)

Consequences for v1:

- The two-lane mempool can still enforce the chained internal order `Urgent* ++ Optimistic*`.
- Urgent txs are not selected for EB in v1. Overflow Urgent txs remain in the mempool until a later RB.
- EB selection is Optimistic-only.
- If we later want Urgent-in-EB, then we must either relax the "urgent ledger service" expectation for
  those txs or change linear-Leios representation/apply semantics so an EB can contribute to urgent
  apply-time service.

## File-by-file change list

| File | Change |
|---|---|
| `Ledger/SupportsMempool.hs` | `MempoolLane` type may live here if shared widely; keep `LedgerSupportsMempool` API minimal if possible. |
| `TxLimits` (`Ledger/SupportsMempool.hs`) | Add `txInclusionLane` defaulting to `UrgentLane`; Dijkstra overrides. |
| `ouroboros-consensus-cardano/.../Shelley/Ledger/Mempool.hs` | Dijkstra `TxLimits` instance: `txInclusionLane` reads `dtbInclusion`; add per-lane capacity helpers if they fit best here. |
| `Mempool/Impl/Common.hs` | `InternalState` -> per-lane fields; chained validation (`urgentState`, then `optimisticState`); urgent admission revalidates optimistic. |
| `Mempool/Update.hs` | `pureTryAddTx` routes by lane; `implSyncWithLedger` revalidates urgent first, optimistic second; manual removal preserves the chain. |
| `Mempool/API.hs` / `Query.hs` | Snapshot API gains lane-aware/selective takes, or a dedicated forge-selection method. |
| `Mempool/Capacity.hs` | Compute `urgentCapacity = 2 * rbCap` and `optimisticCapacity = 2 * ebCap` for Dijkstra/Leios; keep default single-lane behavior elsewhere. |
| `NodeKernel.hs` (diffusion) | Replace prefix/spill cut with urgent-only RB fill and optimistic-only EB fill (no RB filler). |

## Open questions (for Polina / Will — not blocking v1)

1. **Future Urgent-in-EB semantics.** v1 is RB-only for Urgent. If we later re-enable Urgent-in-EB, we
   need a clear linear-Leios apply-time story before calling it urgent service.
2. **Per-lane fairness.** v1 is FIFO per lane and stop-on-first-blocker. Later: fee sorting, RBF, retry
   bands, or skip-on-blocker.
3. **Capacity knobs.** v1 constants are `2 * rbCap` and `2 * ebCap`; expose as config or
   protocol/node parameter later.
4. **Non-Dijkstra eras.** Single effective lane via the default — confirm acceptable.

## Alignment with Polina's mempool sketch

`origin/polina/mempool-spec` is still an Agda/design sketch rather than Haskell, but it may become the
spec direction later. Treat these as deliberate v1 deltas to revisit, not accidental differences:

| Topic | Polina sketch | v1 prototype position |
|---|---|---|
| Lane source | `addTx2 : Lane -> Tx -> ...`; caller supplies `Priority` / `Regular`. | Lane is derived from `dtbInclusion` in the tx body. |
| Ledger stack | `ledgerAt(tip) -> ebLedger -> fastLedger -> ledger`. | `tip -> urgentState -> optimisticState`; no `currentEB` layer in the mempool state for v1. |
| EB semantics | Accepted EB is reapplied first, then both lanes revalidate above it. | Current `leios-prototype` applies EB txs only later at certification; EB txs remain in mempool until certified. |
| Priority/Urgent transport | Priority can appear in EBs and RBs; EB may contain either lane in any order. | Urgent is RB-only in v1; EB selection is Optimistic-only. |
| RB content | `RBFromPrio` takes priority txs up to `prioCap`; no regular RB filler in the sketch. | RB is urgent-only — no Optimistic filler, aligned with the sketch. |
| Capacity | `prioCap = 1 * rbCapacityAt`; `regCap` TBD. | `urgentCapacity = 2 * rbCap`; `optimisticCapacity = 2 * ebCap`, both tunable later. |
| Full-lane behavior | Priority blocked means stop downloading; Regular blocked means discard and continue. | v1 keeps today's mempool behavior for both lanes: no eviction; caller waits/retries when space appears. |
| Tickets | Separate `lastPrioTicket` / `lastRegTicket`; snapshot APIs become lane-aware. | Prefer one global counter initially unless API churn forces per-lane counters. |

The overlap we should preserve while implementing:

- layered sequential validity, with Optimistic/Regular validated after Urgent/Priority;
- priority removal or revalidation cascades into the lower-priority lane;
- order-preserving revalidation and no fee-based reorder/RBF in v1;
- clear separation between admission state and forge-time selection policy.

## Execution path (incremental — build green after each step)

Do it in Claude Code (HLS makes the InternalState refactor's many call-sites tractable). Each step
should leave the affected packages building before the next.

1. **Interface (smallest, isolated).** Add `MempoolLane = UrgentLane | OptimisticLane` and a lane
   classifier, preferably on `TxLimits` with default `UrgentLane`. Build `ouroboros-consensus`.
2. **Dijkstra classifier.** In the Cardano/Dijkstra `TxLimits` instance, implement lane classification
   by reading `dtbInclusion` (Urgent/Optimistic). Build `ouroboros-consensus-cardano`.
3. **State refactor (the invasive one).** In `Mempool/Impl/Common.hs`, split `InternalState` into
   urgent/optimistic sequences, capacities, keys/values, and ledger states. Preserve a global tx-id set
   and a coherent ticket story. Build until green.
4. **Chained revalidation.** Teach `revalidateTxsFor` usage to build `urgentState = tip + urgentTxs`,
   then `optimisticState = urgentState + optimisticTxs`. Build.
5. **Admission.** Route `pureTryAddTx` by lane. Urgent admission validates against urgent state and then
   immediately revalidates optimistic; optimistic admission validates against optimistic state. Enforce
   per-lane capacity. Build.
6. **Manual removal + sync.** Make removal and `implSyncWithLedger` preserve the chained invariant.
   Build.
7. **Capacity helpers.** Compute `rbCap`, `ebCap`, `urgentCapacity = 2 * rbCap`,
   `optimisticCapacity = 2 * ebCap`. Keep non-Leios fallback single-lane. Build.
8. **Snapshot/forge selection.** Add a forge-selection snapshot that returns:
   `rbTxs = urgent RB prefix`, `ebTxs = optimistic EB prefix`, FIFO strict, stop-on-first-blocker, no
   forge-time eviction and no RB filler. Urgent overflow stays in the mempool for a later RB; Optimistic
   overflow for a later EB. Build `ouroboros-consensus-diffusion`.
9. **Tests.** Extend mempool tests:
   - Optimistic is admitted after Urgent and can be invalidated by a later Urgent.
   - Urgent conflict dominates Optimistic.
   - Per-lane capacities are enforced.
   - Reprice eviction drops stale txs via `BidBelowQuote`.
   - Forge fills the RB with Urgent only (no Optimistic filler).
   - EB selection is Optimistic-only.
   - A blocked optimistic prefix stops later optimistic selection.

   **Landed:** the pure forge-selection policy and the `ForgeLaneSummary` counts are covered by
   `Test.Consensus.Mempool.Lanes` — example cases plus QuickCheck properties (RB-within-limit,
   RB-urgent-only, EB-optimistic-only, RB/EB disjoint, summary-matches-selection). All green
   (`cabal run consensus-test -p /Lanes/`).
10. **Build green across the touched packages + run mempool tests + commit** (local only, per the
   no-external-push rule).

Checkpoint after step 5: at that point the lanes physically exist, admission routes by inclusion, and
the core priority invariant (`Urgent*` before `Optimistic*`) is enforced. A natural place to pause and
review before forge-selection complexity.

## EB min-fill rule (2026-07-07, Giorgos's rule — Will: "does actually look quite good")

`selectForForge` only issues an endorser block when the optimistic selection carries at least
**half a regular block** (|RB|/2 = 45,056 bytes); below that the whole selection is withheld and
the transactions **pool in the lane** for the next round (`forgeEndorserBlockHeld`, traced as
`ebHeld=` on the forge-lanes line). Rationale (Slack, validated by Will): in the low-traffic case
nothing is served later than Praos-with-dynamic-pricing would serve it — the second half of the RB
is the controller's headroom, not free space — and Leios's latency becomes better always, with or
without dynamic pricing. The threshold's denominator (RB budget vs the EB's own) is an open weekly
question; the CIP framing (RB) is implemented.
