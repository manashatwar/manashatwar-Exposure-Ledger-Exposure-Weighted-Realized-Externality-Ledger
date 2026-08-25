# Exposure Ledger — Requirements Specification


**Based on:** RESEARCH.md v2.0  
**Target:** Uniswap v4 Hook + Reactive Network  


---

## Document Overview

This document specifies **functional requirements**, **non-functional requirements**, **formal invariants**, **security properties**, and **acceptance criteria** for the Exposure Ledger protocol.

**Notation:** We use semantic variable names from RESEARCH.md throughout.

---

## 1. Functional Requirements

### FR1: Episode Creation

**Trigger:** `afterSwap` hook invocation  
**Purpose:** Create immutable historical record of swap exposure state

**Pre-conditions:**
- `poolManager` is valid Uniswap v4 PoolManager
- Swap has executed successfully
- `nextEpisodeId < type(uint64).max` (no overflow)

**Post-conditions:**
- New episode created with `episodeId = nextEpisodeId`
- `nextEpisodeId` incremented by 1
- Episode data is immutable (cannot be modified)
- `EpisodeCreated` event emitted
- `episodes[episodeId].resolved == false`
- `episodes[episodeId].externality == 0`

**Data Captured:**
```solidity
struct SwapEpisode {
    uint64 episodeId;           // Sequential, unique identifier
    uint64 blockNumber;         // Block.number at creation
    int24 tick;                 // Post-swap tick
    uint160 sqrtPriceX96;       // Post-swap sqrt price (Q64.96)
    uint128 activeLiquidity;    // Total liquidity at tick
    int256 amount0;             // Signed token0 amount
    int256 amount1;             // Signed token1 amount  
    uint8 tradeDirection;       // 0 = sell token0, 1 = buy token0
    uint256 externality;        // Resolved RSPE (0 until resolved)
    bool resolved;              // Resolution status
}
```

**Events:**
```solidity
event EpisodeCreated(
    uint256 indexed episodeId,
    bytes32 indexed poolId,
    uint64 blockNumber,
    int24 tick,
    uint160 sqrtPriceX96,
    uint128 activeLiquidity
);
```

**Acceptance Criteria (SMART):**
- **S**pecific: Episode captures exact pool state post-swap
- **M**easurable: Gas cost ≤ 50,000 gas (measured via forge test --gas-report)
- **A**chievable: Proven in unit test `test_createEpisode_capturesState()`
- **R**elevant: Required for historical exposure tracking
- **T**ime-bound: Implemented in Phase 1 (Week 1)

**Failure Modes:**
| Failure | Cause | Handling |
|---------|-------|----------|
| Episode ID overflow | `nextEpisodeId == type(uint64).max` | Revert with `EpisodeIdOverflow()` |
| Invalid pool state | PoolManager returns zero liquidity | Record actual state, allow resolution to handle |
| Event emission fails | Out of gas | Revert entire transaction (atomicity) |

---

### FR2: LP Exposure Segment Tracking

**Trigger:** `beforeAddLiquidity` and `beforeRemoveLiquidity`  
**Purpose:** Track historical LP exposure periods for attribution

**Pre-conditions (Add):**
- `sender` is valid address
- `liquidityDelta > 0`
- `tickLower < tickUpper`
- `nextEpisodeId` is current

**Pre-conditions (Remove):**
- LP has active segment with `lastEpisodeId == 0`
- `liquidityDelta > 0`
- `liquidityDelta ≤ segment.liquidity`

**Post-conditions (Add):**
- New segment created in `lpSegments[sender]`
- `segment.firstEpisodeId == nextEpisodeId`
- `segment.lastEpisodeId == 0` (active)
- `lpActiveSegmentIndex[sender]` points to new segment

**Post-conditions (Remove - Full):**
- Active segment closed with `lastEpisodeId = nextEpisodeId - 1`
- No new segment created

**Post-conditions (Remove - Partial):**
- Old segment closed with `lastEpisodeId = nextEpisodeId - 1`
- New segment created with reduced liquidity

**Data Structure:**
```solidity
struct LPExposureSegment {
    address lp;                 // LP address  
    int24 tickLower;            // Range lower bound
    int24 tickUpper;            // Range upper bound
    uint128 liquidity;          // Liquidity amount
    uint64 firstEpisodeId;      // First exposed episode
    uint64 lastEpisodeId;       // Last exposed episode (0 = active)
}
```

**Events:**
```solidity
event LPSegmentOpened(
    address indexed lp,
    uint256 segmentIndex,
    uint64 firstEpisodeId,
    int24 tickLower,
    int24 tickUpper,
    uint128 liquidity
);

event LPSegmentClosed(
    address indexed lp,
    uint256 segmentIndex,
    uint64 lastEpisodeId
);
```

**Acceptance Criteria (SMART):**
- **S**: Segment captures complete LP exposure history
- **M**: 
  - At most 1 active segment per LP: `∑ (lastEpisodeId == 0) ≤ 1`
  - Segments never overlap: `seg[i].last < seg[i+1].first`
- **A**: Proven in `test_segmentLifecycle_noOverlap()`
- **R**: Required for historical claim attribution
- **T**: Phase 1 (Week 1)

**Invariants (I2.x):**
- **I2.1 (At Most One Active):** `∀ lp: count(lpSegments[lp] where lastEpisodeId == 0) ≤ 1`
- **I2.2 (Sequential Non-Overlap):** `∀ i: segments[i].lastEpisodeId < segments[i+1].firstEpisodeId`
- **I2.3 (Valid Range):** `∀ segment: tickLower < tickUpper`
- **I2.4 (Positive Liquidity):** `∀ segment: liquidity > 0`

---

### FR3: Reference Price Observation

**Trigger:** Episode created + H blocks elapsed  
**Purpose:** Observe market prices for externality calculation  
**Actor:** Reactive Smart Contract (RSC)

**Pre-conditions:**
- Episode exists and is unresolved
- `block.number >= episode.blockNumber + H`
- Oracle is available and responsive

**Post-conditions:**
- `referencePrice0` and `referencePriceH` obtained
- Prices are within expected range: `0 < price < type(uint256).max`
- Prices are fresh: `priceTimestamp >= requiredTimestamp`

**Interface:**
```solidity
interface IReferencePriceOracle {
    /// @notice Get reference market price at specific block
    /// @param blockNumber Block to query
    /// @return price Price in token1/token0 format (18 decimals)
    /// @return timestamp Price timestamp (must be recent)
    function getPriceAt(uint256 blockNumber) 
        external view returns (uint256 price, uint256 timestamp);
}
```

**Configuration Parameters:**
- **Observation Horizon (H):** 50 blocks (~10 minutes)
- **Price Format:** token1/token0, 18 decimals
- **Staleness Tolerance:** Price timestamp within 5 blocks of query
- **Price Sanity Bounds:** `minPrice < price < maxPrice` (configurable per pool)

**Acceptance Criteria (SMART):**
- **S**: Oracle provides prices at t=0 and t=H
- **M**: 
  - Price staleness ≤ 5 blocks: `block.number - priceTimestamp ≤ 5`
  - Price within bounds: `10^12 < price < 10^24` (covers 10^-6 to 10^6 ratios)
- **A**: Proven in `test_oracle_providesFreshPrices()`
- **R**: Required for RSPE calculation
- **T**: Phase 1 (Week 2)

**Failure Modes:**
| Failure | Cause | Handling |
|---------|-------|----------|
| Oracle unresponsive | Network issue, oracle down | Skip resolution, retry later |
| Stale price | Price timestamp too old | Skip resolution, emit `StalePrice` event |
| Price out of bounds | Manipulation or error | Skip resolution, emit `PriceOutOfBounds` |
| Oracle reverts | Invalid input | Catch revert, skip resolution gracefully |

---

### FR4: Externality Calculation

**Trigger:** Reference prices obtained  
**Purpose:** Calculate RSPE = min(staleOpportunity, adverseMarkout)  
**Actor:** Reactive Smart Contract

**Pre-conditions:**
- Episode data available
- `referencePrice0` and `referencePriceH` valid
- `poolPrice` extracted from episode

**Post-conditions:**
- `episodeExternality` calculated
- `0 ≤ episodeExternality ≤ max(staleOpportunity, adverseMarkout)`
- Callback emitted to origin chain

**Formula Implementation:**
```solidity
/// @notice Calculate realized stale-price externality
/// @param episode The swap episode data
/// @param referencePrice0 Reference price at episode time
/// @param referencePriceH Reference price after horizon H
/// @return externality Calculated RSPE
function calculateExternality(
    SwapEpisode memory episode,
    uint256 referencePrice0,
    uint256 referencePriceH
) internal pure returns (uint256 externality) {
    uint256 poolPrice = _sqrtPriceToPrice(episode.sqrtPriceX96);
    
    // Calculate stale opportunity D(e)
    int256 priceGap0 = int256(referencePrice0) - int256(poolPrice);
    uint256 staleOpportunity = episode.tradeDirection == 0
        ? (priceGap0 > 0 ? uint256(priceGap0) * uint256(episode.amount0) / 1e18 : 0)
        : (priceGap0 < 0 ? uint256(-priceGap0) * uint256(episode.amount0) / 1e18 : 0);
    
    // Calculate adverse markout A(e)
    int256 priceGapH = int256(referencePriceH) - int256(poolPrice);
    uint256 adverseMarkout = episode.tradeDirection == 0
        ? (priceGapH > 0 ? uint256(priceGapH) * uint256(episode.amount0) / 1e18 : 0)
        : (priceGapH < 0 ? uint256(-priceGapH) * uint256(episode.amount0) / 1e18 : 0);
    
    // RSPE = min(D, A) - conservative estimate
    externality = staleOpportunity < adverseMarkout 
        ? staleOpportunity 
        : adverseMarkout;
}
```

**Acceptance Criteria (SMART):**
- **S**: Implements RSPE formula from RESEARCH.md §3.3
- **M**:
  - Conservativeness: `externality ≤ min(D, A)`
  - Direction correctness: Positive externality only when pool disadvantaged
  - Test vectors: 100% pass rate on 20 test cases
- **A**: Proven in `test_rspe_conservativeness()` and `test_rspe_directionality()`
- **R**: Core protocol primitive
- **T**: Phase 1 (Week 2)

**Edge Cases:**
| Case | Condition | Expected Result |
|------|-----------|-----------------|
| No stale gap | `referencePrice0 == poolPrice` | `externality = 0` |
| Favorable markout | Price moved favorably for pool | `externality = 0` |
| Both zero | No opportunity and no markout | `externality = 0` |
| Extreme values | Prices near uint256 bounds | No overflow, safe math |

---

### FR5: Episode Resolution Callback

**Trigger:** Externality calculated in RSC  
**Purpose:** Push resolved externality to origin chain  
**Actor:** Reactive callback proxy

**Pre-conditions:**
- Episode exists and is unresolved
- `msg.sender == callbackProxy`
- `externality` is valid (calculated correctly)

**Post-conditions:**
- `episodes[episodeId].externality = externality`
- `episodes[episodeId].resolved = true`
- Attribution triggered automatically
- `EpisodeResolved` event emitted

**Interface:**
```solidity
/// @notice Resolve episode with calculated externality
/// @dev Only callable by Reactive callback proxy
/// @param episodeId Episode to resolve
/// @param externality Calculated RSPE value
function resolveEpisode(
    uint256 episodeId,
    uint256 externality
) external onlyCallbackProxy {
    SwapEpisode storage episode = episodes[episodeId];
    require(!episode.resolved, "Already resolved");
    
    episode.externality = externality;
    episode.resolved = true;
    
    emit EpisodeResolved(episodeId, externality);
    
    _attributeExternality(episodeId);
}
```

**Events:**
```solidity
event EpisodeResolved(
    uint256 indexed episodeId,
    uint256 externality,
    uint256 timestamp
);
```

**Acceptance Criteria (SMART):**
- **S**: Episode transitions from unresolved to resolved exactly once
- **M**:
  - Idempotency: Second call reverts with `AlreadyResolved`
  - Authorization: Only callback proxy succeeds
  - Attribution triggered: `sum(lpAttribution) == externality` (within rounding)
- **A**: Proven in `test_resolution_idempotent()` and `test_resolution_authorization()`
- **R**: Critical for protocol correctness
- **T**: Phase 2 (Week 2)

**Security Properties (S5.x):**
- **S5.1 (Authorization):** `msg.sender == callbackProxy ∨ revert`
- **S5.2 (Idempotency):** `resolved == true ⇒ revert on re-call`
- **S5.3 (Atomicity):** Resolution and attribution in single transaction
- **S5.4 (Non-malleability):** Once resolved, externality immutable

---

### FR6: Manual Fallback Resolution

**Trigger:** Episode unresolved after 7 days (Reactive failure)  
**Purpose:** Provide fallback mechanism when Reactive Network fails  
**Actor:** Contract owner (emergency)

**Pre-conditions:**
- Episode exists and is unresolved
- `block.timestamp >= episode.createdTimestamp + 7 days`
- `msg.sender == owner`
- Owner provides externality value with proof

**Post-conditions:**
- Episode marked as resolved
- `episodes[episodeId].resolved == true`
- `episodes[episodeId].externality == providedValue`
- Attribution executed
- Event emitted with manual resolution flag

**Interface:**
```solidity
/// @notice Manual resolution fallback (owner-only after timeout)
/// @param episodeId Episode to resolve
/// @param externality Calculated RSPE value
/// @param proof Off-chain calculation proof (for transparency)
function manualResolveEpisode(
    uint256 episodeId,
    uint256 externality,
    bytes calldata proof
) external onlyOwner {
    SwapEpisode storage episode = episodes[episodeId];
    require(!episode.resolved, "Already resolved");
    require(
        block.timestamp >= episode.createdTimestamp + 7 days,
        "Timeout not reached"
    );
    
    _resolveEpisode(episodeId, externality);
    emit ManualResolution(episodeId, externality, proof);
}
```

**Acceptance Criteria (SMART):**
- **S**: Owner can manually resolve after 7-day timeout
- **M**:
  - Timeout enforced: Reverts before 7 days
  - Single resolution: Cannot re-resolve
  - Attribution executed: Same logic as automatic
- **A**: Proven in `test_manualResolution_afterTimeout()`
- **R**: Critical fallback for Reactive failure
- **T**: Phase 1 (Week 3)

**Security Properties:**
- **S6.1**: Only owner can manually resolve
- **S6.2**: 7-day waiting period prevents premature intervention
- **S6.3**: Event with proof provides transparency/auditability
- **S6.4**: Manual resolution uses same attribution logic (no special path)

---

### FR7: Exposure-Weighted Attribution

**Trigger:** Episode resolved  
**Purpose:** Distribute externality to exposed LPs proportionally  
**Actor:** Hook contract (internal)

**Pre-conditions:**
- Episode resolved with `externality > 0`
- LP segments exist for episode period
- Active liquidity > 0

**Post-conditions:**
- All exposed LPs attributed
- `∑ lpAttribution ≤ episodeExternality` (equality under exact arithmetic)
- `ExternalityAttributed` events emitted for each LP
- `lpTotalExternality[lp]` updated for each exposed LP

**Algorithm (Gas-Optimized):**
```solidity
/// @notice Attribute externality to exposed LPs
/// @param episodeId Episode to attribute
function _attributeExternality(uint256 episodeId) internal {
    SwapEpisode storage episode = episodes[episodeId];
    
    if (episode.externality == 0) return; // No externality to attribute
    
    // Zero liquidity guard (from ARCHITECTURE_VALIDATION.md §4.5)
    if (episode.activeLiquidity == 0) {
        // Cannot attribute (no one was exposed)
        // Mark resolved without attribution
        emit ZeroLiquidityEpisode(episodeId);
        return;
    }
    
    // Use pre-computed exposed LP list (built during add/remove liquidity)
    address[] memory exposedLPs = episodeExposedLPs[episodeId];
    
    for (uint256 i = 0; i < exposedLPs.length; i++) {
        address lp = exposedLPs[i];
        LPExposureSegment memory segment = _getActiveSegment(lp, episodeId);
        
        // Calculate exposure share
        uint256 exposureShare = (uint256(segment.liquidity) * PRECISION) 
                                 / uint256(episode.activeLiquidity);
        uint256 attribution = (episode.externality * exposureShare) / PRECISION;
        
        // Accumulate
        lpTotalExternality[lp] += attribution;
        lpEpisodeAttribution[lp][episodeId] = attribution;
        
        emit ExternalityAttributed(lp, episodeId, attribution);
    }
}
```

**Acceptance Criteria (SMART):**
- **S**: Proportional attribution based on liquidity share
- **M**:
  - Soundness: `∑ attribution ≤ externality`
  - Fairness: `attribution_i / attribution_j == liquidity_i / liquidity_j` for exposed LPs
  - Gas efficiency: `O(N_exposed)` where `N_exposed` typically < 100
  - Rounding error: `|∑ attribution - externality| < N_exposed` (dust accumulation)
  - **Zero liquidity safety:** No division by zero when `activeLiquidity == 0`
- **A**: Proven in `test_attribution_soundness()`, `test_attribution_fairness()`, and `test_zeroLiquidity_skipAttribution()`
- **R**: Core value proposition of protocol
- **T**: Phase 2 (Week 3)

**Invariants (I7.x):**
- **I7.1 (Soundness):** `∀ e: ∑_{p} C_p(e) ≤ ℰ(e)`
- **I7.2 (Non-Negative):** `∀ p, e: C_p(e) ≥ 0`
- **I7.3 (No Attribution Without Exposure):** `exposureIndicator(p,e) == 0 ⇒ C_p(e) == 0`
- **I7.4 (Monotonicity):** `lpTotalExternality[p]` never decreases
- **I7.5 (Zero Liquidity Safety):** `activeLiquidity == 0 ⇒ skip attribution` *(added from ARCHITECTURE_VALIDATION.md)*

---

### FR7: LP Dashboard Queries

**Purpose:** Enable LPs to query exposure history and attribution  
**Actor:** External view functions (off-chain access)

**Interfaces:**
```solidity
/// @notice Get LP's total cumulative externality
function getLPTotalExternality(address lp) 
    external view returns (uint256);

/// @notice Get LP's complete exposure history
function getLPExposureHistory(address lp) 
    external view returns (LPExposureSegment[] memory);

/// @notice Get LP's attribution for specific episode
function getLPEpisodeAttribution(address lp, uint256 episodeId) 
    external view returns (uint256);

/// @notice Get complete episode details
function getEpisodeDetails(uint256 episodeId) 
    external view returns (SwapEpisode memory);

/// @notice Get LP statistics (aggregated)
function getLPStats(address lp) external view returns (
    uint256 totalExternality,
    uint256 episodesExposed,
    uint256 largestEpisode,
    uint256 averageEpisodeImpact
);
```

**Acceptance Criteria (SMART):**
- **S**: All view functions gas-efficient (no unbounded iteration)
- **M**:
  - Response time: < 100k gas per query
  - Data completeness: 100% of historical segments retrievable
  - Correctness: `getLPTotalExternality == ∑ getLPEpisodeAttribution`
- **A**: Proven in `test_queries_gasEfficient()` and `test_queries_correctness()`
- **R**: Required for LP transparency
- **T**: Phase 2 (Week 3)

---

## 2. Non-Functional Requirements

### NFR1: Gas Efficiency

**Requirements:**
- Episode creation: ≤ 50,000 gas overhead
- Segment open/close: ≤ 30,000 gas
- Attribution per LP: ≤ 100,000 gas total (not per LP)
- View queries: ≤ 100,000 gas

**Measurement:** Foundry `forge test --gas-report`

**Acceptance:** All functions meet gas targets in 95th percentile

### NFR2: Security

**Properties:**
- **Authorization:** Only designated roles can call privileged functions
- **Reentrancy:** All state-modifying functions are reentrancy-safe
- **Integer Safety:** No overflow/underflow (Solidity 0.8+ checked arithmetic)
- **Access Control:** Episode resolution only by callback proxy
- **Immutability:** Historical data never modified after creation

**Verification:** Slither analysis with zero high/critical issues

### NFR3: Observability

**Requirements:**
- All state changes emit events
- Events include indexed fields for efficient filtering
- Event data sufficient to reconstruct state off-chain

**Events Summary:**
- `EpisodeCreated` - Episode lifecycle
- `EpisodeResolved` - Resolution tracking
- `LPSegmentOpened` / `LPSegmentClosed` - LP lifecycle
- `ExternalityAttributed` - Attribution tracking

### NFR4: Scalability

**Limits:**
- Max LPs per pool: 10,000 (practical limit)
- Max segments per LP: 100
- Max active episodes: unbounded (pruning required for production)

**Mitigation:**
- Lazy attribution (LPs claim own rewards)
- Exposure bitmap for gas-efficient iteration
- Episode archival after expiry period

---

## 3. System Invariants

### Global Invariants (I.G)

**I.G.1 (Episode ID Sequential):**
```
∀ i: episodes[i].episodeId == i
```

**I.G.2 (Resolution One-Way):**
```
episodes[e].resolved == true ⇒ ∀ future states: episodes[e].resolved == true
```

**I.G.3 (Attribution Conservation):**
```
∀ e: ∑_{p ∈ allLPs} lpEpisodeAttribution[p][e] ≤ episodes[e].externality
```

**I.G.4 (Non-Negative Attribution):**
```
∀ p, e: lpEpisodeAttribution[p][e] ≥ 0 ∧ lpTotalExternality[p] ≥ 0
```

### State Transition Invariants (I.T)

**I.T.1 (Episode Creation):**
```
Pre: nextEpisodeId == n
Post: nextEpisodeId == n + 1 ∧ episodes[n] exists
```

**I.T.2 (Segment Lifecycle):**
```
Open: lastEpisodeId == 0
Closed: lastEpisodeId > 0 ∧ lastEpisodeId < nextEpisodeId
```

**I.T.3 (Resolution Atomicity):**
```
resolveEpisode(e, ℰ) ⇒ 
    (episodes[e].resolved == true ∧ 
     episodes[e].externality == ℰ ∧
     ∑ attributions computed)
```

---

## 4. Security Requirements

### Access Control Matrix

| Function | Authorized Caller | Unauthorized Behavior |
|----------|-------------------|----------------------|
| `afterSwap` | PoolManager | Revert |
| `beforeAddLiquidity` | PoolManager | Revert |
| `beforeRemoveLiquidity` | PoolManager | Revert |
| `resolveEpisode` | Callback Proxy | Revert |
| View functions | Anyone | Read-only access |

### Threat Mitigation

| Threat | Severity | Mitigation | Verification |
|--------|----------|-----------|--------------|
| Oracle manipulation | Critical | Multi-oracle, TWAP, bounds checking | Manual review + simulation |
| Attribution DoS | High | Gas-efficient iteration, batch processing | Gas profiling |
| Reentrancy | High | CEI pattern, reentrancy guards | Slither analysis |
| Integer overflow | Medium | Solidity 0.8+ | Compiler enforced |
| Unauthorized resolution | Critical | Access control | Unit tests |

---

## 5. Testing Requirements

### Unit Tests (≥95% coverage)

**Episode Tests:**
- `test_createEpisode_capturesState()`
- `test_createEpisode_emitsEvent()`
- `test_createEpisode_gasEfficient()`

**Segment Tests:**
- `test_segmentLifecycle_addRemove()`
- `test_segmentLifecycle_partialRemove()`
- `test_segmentInvariants_noOverlap()`
- `test_segmentInvariants_atMostOneActive()`

**Attribution Tests:**
- `test_attribution_soundness_sumLessEqual()`
- `test_attribution_fairness_proportional()`
- `test_attribution_edgeCase_zeroExternality()`
- `test_attribution_edgeCase_singleLP()`

### Integration Tests

**End-to-End:**
- `test_e2e_swapToAttribution()`
- `test_e2e_multipleSwaps()`
- `test_e2e_multipleLPs()`
- `test_e2e_lpRemovesBeforeResolution()`

### Testnet Validation

**Sepolia Deployment:**
1. Deploy contracts
2. Initialize pool with test tokens
3. Execute 100 swaps
4. Verify all episodes resolve
5. Validate attribution correctness
6. Gas profiling on real network

**Success Criteria:**
- 100% episode resolution rate
- Attribution error < 0.1%
- Gas costs within NFR1 limits

---

## 6. Acceptance Criteria Summary

| Requirement | Metric | Target | Verification |
|-------------|--------|--------|--------------|
| FR1: Episode creation | Gas cost | ≤ 50k | `forge test --gas-report` |
| FR2: Segment tracking | Invariants | 100% hold | Property tests |
| FR3: Price observation | Staleness | ≤ 5 blocks | Oracle tests |
| FR4: RSPE calculation | Conservativeness | 100% | Proof + tests |
| FR5: Resolution | Idempotency | 100% | Unit tests |
| FR6: Attribution | Soundness | `∑C ≤ ℰ` always | Property tests |
| FR7: Queries | Gas cost | ≤ 100k | Gas profiling |
| NFR1: Gas | All functions | Within limits | Profiling |
| NFR2: Security | Slither | 0 critical | Static analysis |
| NFR3: Events | Coverage | 100% state changes | Manual review |

---

## 7. Out of Scope (Future Work)

The following are explicitly **not** required for initial production deployment:

- Dynamic horizon selection
- Multi-tick exact weighting
- Cross-pool correlation tracking
- Real-time exposure estimation
- MEV rebate mechanisms
- Insurance payouts
- Governance mechanisms
- On-chain archival/pruning (manual admin function acceptable)

---

## Document Navigation

- **Mathematical foundation** → See `RESEARCH.md`
- **Technical implementation** → See `DESIGN.md`
- **Project overview** → See `../PROJECT_OVERVIEW.md`
