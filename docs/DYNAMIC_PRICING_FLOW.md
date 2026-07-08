# Dynamic Pricing — design flow (tx + block lifecycle)

Visual companion to [`DYNAMIC_PRICING_LEDGER_RULES.md`](./DYNAMIC_PRICING_LEDGER_RULES.md).
Shows where each ledger rule acts on a transaction and how the pricing state evolves
from one block to the next. Praos-only (every block is an RB).

> Renders natively in VSCode (Markdown Preview) and on GitHub. Edit the mermaid block
> below as the implementation evolves — keep it in sync with the spec sections (s1–s5).

```mermaid
flowchart TD
    classDef fail fill:#fde4e4,stroke:#c0392b,color:#7b1f1f;
    classDef open fill:#fff4d6,stroke:#d4a017,color:#7a5a00;
    classDef state fill:#e6f0ff,stroke:#3b6fb0,color:#1f3d66;

    %% ---------- Submission ----------
    subgraph SUB[Submission]
        direction TB
        TX["Tx<br/>dtbInclusion: Urgent | Optimistic<br/>dtbBidFee — price cap<br/>dtbFeeRefundAccount?"]
        MEM["MEMPOOL<br/>judged vs current published prices"]
        TX --> MEM
    end

    %% ---------- UTXO rule ----------
    subgraph UTXO["UTXO rule — per tx (s2, s3)"]
        direction TB
        U1{"U1 — quoteFor(pp, tx, priceOf i) ≤ dtbBidFee ?"}
        BBQ["BidBelowQuote{expected, supplied}"]:::fail
        U2["U2 — recordTx i size fee exUnits<br/>→ accumulate blockUsage"]
        SPLIT["Fee split (when feeRefundAccount = Just)<br/>base → fee pot<br/>premium = quote − base → donation / treasury<br/>refund = dtbBidFee − quote → pendingRefunds"]
        U1 -- "no" --> BBQ
        U1 -- "yes" --> U2 --> SPLIT
    end

    %% ---------- LEDGER rule ----------
    subgraph LED["LEDGER rule — per tx (s4)"]
        FLUSH["flushPendingRefunds<br/>credit registered accounts → rewards<br/>pendingRefunds := ∅"]
    end

    %% ---------- BBODY rule ----------
    subgraph BB["BBODY — end of block, after all txs (s5)"]
        direction TB
        B1{"B1 — sdChecks: Optimistic usage (bytes + ExUnits) ≤ RB limits ?"}
        OVF["OptimisticOverflowsBlock{,ExUnits}"]:::fail
        B2["B2 — endOfBlock<br/>reprice + reset blockUsage := ∅"]
        REPRICE["reprice = EIP-1559 controller (Will) ✓<br/>target ½, D=4 · optimistic signal open (Q4)"]:::open
        B1 -- "no" --> OVF
        B1 -- "yes" --> B2
        B2 -.->|"currently"| REPRICE
    end

    %% ---------- wiring ----------
    MEM --> U1
    SPLIT --> FLUSH
    FLUSH -->|"more txs in block"| U1
    FLUSH -->|"end of block"| B1

    %% ---------- temporal loop ----------
    B2 ==>|"publishedPrices(block N) judge the txs of block N+1"| MEM
```

## Legend

- 🔴 red nodes — the four new predicate failures (`BidBelowQuote`,
  `OptimisticOverflowsBlock`, `OptimisticOverflowsBlockExUnits`).
- 🟡 yellow node — `reprice` now runs Will's per-strategy EIP-1559 controller
  (`stepPrice`, target ½, D=4); what stays open is the optimistic-lane signal (Q4),
  window smoothing, and the overflow term.
- The **bold loop** is the temporal semantics: the prices published at the end of
  block *N* are what the UTXO rule (and the mempool) judge block *N+1* against.

## Where the state lives (for reference)

The flow above mutates `DynamicPricing` (Dijkstra's `PricingState`, carried by
`UTxOState.utxosPricing`): `publishedPrices` (read by U1, rewritten by B2),
`blockUsage` (written by U2, reset by B2), `pendingRefunds` (written by the fee split,
drained by the LEDGER flush). See spec s1 for the `EraPricing` era-family.
