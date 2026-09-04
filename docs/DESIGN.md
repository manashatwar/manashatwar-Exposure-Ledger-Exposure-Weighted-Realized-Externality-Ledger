# Exposure Ledger — Technical Design Specification


**Based on:** RESEARCH.md  REQUIREMENTS.md  

---

## Document Overview

This document provides **complete technical specifications** for implementing the Exposure Ledger protocol, including:
- Formal state machine models
- Complete contract interfaces
- Security architecture and threat model
- Gas-optimized implementation strategies
- Comprehensive error handling
- Testing and verification approach

---

## 1. System Architecture

### 1.1 Component Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    ETHEREUM SEPOLIA (Origin Chain)               │
│                                                                  │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  ExposureLedgerHook                                    │    │
│  │  (Uniswap v4 Hook - Singleton Pattern)                │    │
│  │                                                         │    │
│  │  State Storage:                                        │    │
│  │  • episodes: mapping(uint256 => SwapEpisode)           │    │
│  │  • lpSegments: mapping(address => Segment[])           │    │
│  │  • lpTotalExternality: mapping(address => uint256)     │    │
│  │  • episodeExposedLPs: mapping(uint256 => address[])    │    │
│  │                                                         │    │
│  │  Hook Points:                                          │    │
│  │  ├─ afterSwap() → createEpisode()                      │    │
│  │  ├─ beforeAddLiquidity() → openSegment()               │    │
│  │  └─ beforeRemoveLiquidity() → closeSegment()           │    │
│  │                                                         │    │
│  │  Callback:                                             │    │
│  │  └─ resolveEpisode() → _attributeExternality()         │    │
│  └────────────────────────────────────────────────────────┘    │
│                           │                                      │
│                           │ EpisodeCreated events                │
└───────────────────────────┼──────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                 REACTIVE NETWORK (Lasna)                         │
│                                                                  │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  ExposureLedgerRSC                                     │    │
│  │  (Reactive Smart Contract)                             │    │
│  │                                                         │    │
│  │  Lifecycle:                                            │    │
│  │  1. Subscribe to EpisodeCreated                        │    │
│  │  2. react() receives event                             │    │
│  │  3. Store episode in pending queue                     │    │
│  │  4. Wait H blocks                                      │    │
│  │  5. Query oracle for P_ref^0 and P_ref^H              │    │
│  │  6. Calculate RSPE = min(D, A)                         │    │
│  │  7. Emit callback to resolveEpisode()                  │    │
│  │                                                         │    │
│  │  Dependencies:                                         │    │
│  │  • IReferencePriceOracle (Chainlink/TWAP)             │    │
│  │  • ISystemContract (Reactive runtime)                  │    │
│  └────────────────────────────────────────────────────────┘    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 1.2 Data Flow Sequence

```
┌─────┐     ┌──────┐     ┌──────┐     ┌─────────┐     ┌──────────┐
│Swap │────▶│ Hook │────▶│Event │────▶│Reactive │────▶│Resolution│
└─────┘     └──────┘     └──────┘     └─────────┘     └──────────┘
             │                            │                 │
             │ Record State               │ Observe         │ Attribute
             │ • tick                     │ • P_ref^0       │ • Calculate shares
             │ • liquidity                │ • P_ref^H       │ • Update balances
             │ • amounts                  │ • RSPE          │ • Emit events
             ▼                            ▼                 ▼
        [Episodes DB]              [Oracle Query]      [LP Balances]
```

---

## 2. State Machine Specifications

### 2.1 Episode Lifecycle State Machine

```
                    ┌─────────────┐
                    │   [START]   │
                    └──────┬──────┘
                           │
                    afterSwap()
                           │
                           ▼
                  ┌────────────────┐
                  │    CREATED     │◀─────────┐
                  │                │          │
                  │ resolved=false │          │ RSC observes
                  │ externality=0  │          │ but not ready
                  └────────┬───────┘          │
                           │                   │
                  H blocks elapsed             │
                  Oracle available             │
                           │                   │
                           ▼                   │
                  ┌────────────────┐          │
                  │   RESOLVING    │──────────┘
                  │                │
                  │ RSC calculating│
                  │ RSPE           │
                  └────┬───────┬───┘
                       │       │
                       │       │ Reactive Fails
                       │       │ After 7 days
                       │       │
                       │       ▼
                       │  ┌────────────────┐
                       │  │ PENDING_MANUAL │
                       │  │                │
                       │  │ Awaiting owner │
                       │  │ resolution     │
                       │  └───────┬────────┘
                       │          │
                       │   manualResolve()
                       │          │
                       └──────────┴────────┐
                                           │
                  resolveEpisode(e, ℰ)     │
                           │               │
                           ▼               │
                  ┌────────────────┐      │
                  │   RESOLVED     │◀─────┘
                  │                │
                  │ resolved=true  │────────▶ Attribution
                  │ externality=ℰ  │          Complete
                  └────────────────┘
                           │
                           │ [TERMINAL]
                           ▼
```

**State Transition Rules:**

| Current State | Event | Pre-conditions | Next State | Post-conditions |
|--------------|-------|----------------|------------|-----------------|
| START | `afterSwap()` | Pool active | CREATED | Episode exists, event emitted |
| CREATED | H blocks pass | Oracle ready | RESOLVING | RSC triggered |
| CREATED | 7 days timeout | No resolution | PENDING_MANUAL | Manual fallback enabled |
| RESOLVING | `resolveEpisode()` | msg.sender==reactiveProxy | RESOLVED | Attribution executed |
| PENDING_MANUAL | `manualResolveEpisode()` | msg.sender==owner | RESOLVED | Manual attribution |
| RESOLVED | (none) | — | RESOLVED | Terminal state |

**Invalid Transitions (must revert):**
- RESOLVED → CREATED (no state regression)
- CREATED → RESOLVED without resolution call
- Multiple resolutions of same episode
- Manual resolution before timeout

**Added in v2.1 (from ARCHITECTURE_VALIDATION.md):**
- PENDING_MANUAL state for Reactive failure handling
- 7-day timeout for manual fallback
- Owner-only manual resolution

### 2.2 LP Segment Lifecycle State Machine

```
                    ┌─────────────┐
                    │   [START]   │
                    └──────┬──────┘
                           │
                  beforeAddLiquidity()
                           │
                           ▼
                  ┌────────────────┐
                  │   ACTIVE       │◀──────────┐
                  │                │           │
                  │ lastEpisodeId  │           │ Partial
                  │   == 0         │           │ Remove
                  └────┬───────┬───┘           │
                       │       │               │
       Full Remove     │       │ Add More      │
                       │       │ Liquidity     │
                       │       │               │
                       │       └───────────────┘
                       │
                       ▼
                  ┌────────────────┐
                  │   CLOSED       │
                  │                │
                  │ lastEpisodeId  │────────▶ Historical
                  │   > 0          │          Claims Valid
                  └────────────────┘
                           │
                           │ [TERMINAL]
                           ▼
```

**Invariants:**
- I.S.1: At most one ACTIVE segment per LP
- I.S.2: CLOSED segments immutable
- I.S.3: Episode IDs monotonically increasing
- I.S.4: Historical claims valid even after CLOSED

---


## 4. Security Analysis

### 4.1 Threat Model

**Adversarial Capabilities:**
- Control transaction ordering (MEV)
- Manipulate oracle (if weak)
- Create many small LP positions (gas attack)
- Front-run/back-run Reactive callbacks

**System Assumptions:**
- Uniswap v4 PoolManager is trustworthy
- Reactive Network callback proxy is trustworthy
- At least one honest oracle source exists

### 4.2 Attack Tree

```
[Goal: Extract Value or Disrupt Service]
    │
    ├── Oracle Manipulation
    │   ├── Flash loan attack on reference pool
    │   ├── TWAP manipulation
    │   └── Mitigation: Multi-oracle + bounds checking
    │
    ├── Attribution Gas Attack
    │   ├── Create 10,000 tiny LP positions
    │   ├── Force O(N) iteration in attribution
    │   └── Mitigation: Pre-computed exposed LP lists
    │
    ├── Resolution DoS
    │   ├── Prevent Reactive callbacks
    │   ├── Block episode resolution
    │   └── Mitigation: Manual resolution fallback
    │
    └── Reentrancy
        ├── Malicious callback during attribution
        ├── Re-enter attribution logic
        └── Mitigation: CEI pattern + ReentrancyGuard
```

### 4.3 Security Properties

**Property 1 (Episode Immutability):**
```
∀ e, t1, t2: episodes[e]@t1 == episodes[e]@t2  (except resolution)
```

**Property 2 (Attribution Soundness):**
```
∀ e: ∑_{p} lpEpisodeAttribution[p][e] ≤ episodes[e].externality
```

**Property 3 (Authorization):**
```
resolveEpisode(e, ℰ) succeeds ⟺ msg.sender == callbackProxy
```

**Property 4 (Monotonicity):**
```
∀ p, t1 < t2: lpTotalExternality[p]@t1 ≤ lpTotalExternality[p]@t2
```

---

## 5. Gas Optimization Strategy

### 5.1 Storage Optimization

| Operation | Naive | Optimized | Savings |
|-----------|-------|-----------|---------|
| Episode creation | 5 SSTOREs | 1 packed struct | ~40% |
| LP tracking | Linear search | Bitmap index | ~70% |
| Attribution | O(N_LPs) | O(N_exposed) | ~90% |

### 5.2 Implementation Pattern

```solidity
// BAD: O(N_LPs) iteration
for (uint i = 0; i < allLPs.length; i++) {
    if (isExposed(allLPs[i], episode)) {
        attribute(allLPs[i], episode);
    }
}

// GOOD: O(N_exposed) pre-computed
for (uint i = 0; i < exposedLPs[episodeId].length; i++) {
    attribute(exposedLPs[episodeId][i], episode);
}
```

---

## 6. Testing Strategy

### 6.1 Unit Test Coverage

```solidity
// Episode tests
test_createEpisode_capturesState()
test_createEpisode_emitsEvent()
test_createEpisode_revertsOnOverflow()
test_createEpisode_revertsOnZeroLiquidity()

// Segment tests
test_openSegment_createsActive()
test_closeSegment_full()
test_closeSegment_partial()
test_segmentInvariants_noOverlap()
test_segmentInvariants_atMostOneActive()

// Resolution tests
test_resolveEpisode_updatesState()
test_resolveEpisode_revertsIfUnauthorized()
test_resolveEpisode_revertsIfAlreadyResolved()
test_resolveEpisode_triggersAttribution()

// Attribution tests
test_attribution_soundness()
test_attribution_fairness()
test_attribution_gasEfficiency()
test_attribution_roundingError()
```

### 6.2 Integration Tests

```solidity
test_e2e_singleSwap()
test_e2e_multipleSwaps()
test_e2e_multipleLPs()
test_e2e_lpRemovesBeforeResolution()
test_e2e_reactiveCallback()
```

### 6.3 Fuzz Testing

```solidity
testFuzz_attribution(uint256 externality, uint128[] lpLiquidities)
testFuzz_segmentLifecycle(int24 tickLower, int24 tickUpper, uint128 liquidity)
testFuzz_priceCalculation(uint160 sqrtPriceX96)
```

---

## 7. Deployment Checklist

- [ ] Audit by reputable firm (Trail of Bits, OpenZeppelin, etc.)
- [ ] Slither analysis: 0 critical/high issues
- [ ] Forge test coverage: ≥95%
- [ ] Gas profiling: All functions within NFR limits
- [ ] Testnet validation: 1000+ episodes resolved successfully
- [ ] Oracle integration tested
- [ ] Reactive callback verified
- [ ] Emergency pause mechanism reviewed
- [ ] Documentation complete
- [ ] Monitoring/alerting configured

---

## 8. Future Enhancements

### Production Roadmap

**Phase 2: Gas Optimization**
- Implement bitmap-based LP indexing
- Add batch attribution
- Episode archival mechanism

**Phase 3: Oracle Hardening**
- Multi-oracle aggregation
- TWAP implementation
- Manipulation detection

**Phase 4: Advanced Features**
- Adaptive horizon selection
- Multi-tick exact weighting
- Cross-pool correlation

---

## Document Navigation

- **Research foundation** → See `RESEARCH.md`
- **Requirements specification** → See `REQUIREMENTS.md`
- **Project overview** → See `../PROJECT_OVERVIEW.md`
