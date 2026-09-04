# Exposure Ledger — Position-Level MEV Attribution for Uniswap v4

 
**Version:** v1.0 (First Version)  
**Target:** Uniswap v4 + Reactive Network

---

## Overview

**Exposure Ledger** is a protocol-native system that measures and attributes **realized MEV (stale-price externalities)** to individual liquidity provider (LP) positions in Uniswap v4 concentrated liquidity markets.

Unlike existing pool-level LVR metrics, Exposure Ledger provides **position-level transparency**: each LP can see exactly how much adverse selection their specific position bore, enabling informed decisions about range selection, pool choice, and LP strategy.

### The Problem

Current AMM analytics show pool-level averages:
- "This pool earned $100K in fees"
- "This pool had $50K LVR"

But LPs can't answer:
- **"How much MEV did MY position eat?"**
- **"Was my tight range worth the adverse selection?"**
- **"Am I being JIT'd by sophisticated LPs?"**

### The Solution

Exposure Ledger tracks:
1. **Every swap** creates an immutable "Episode" (snapshot of pool state)
2. **LP exposure** tracked via segments (who was exposed when)
3. **Async resolution** measures realized adverse selection after observing future prices
4. **Attribution** distributes MEV proportionally to exposed LPs

**Result:** Each LP gets their **MEV-adjusted P&L** = Fees Earned - Realized Adverse Selection

---

## Architecture

```
┌─────────────┐   Swap    ┌──────────────────┐   EpisodeCreated   ┌────────────────┐
│   Trader    │─────────▶ │ ExposureLedger   │───────────────────▶│ ReactiveRSC    │
└─────────────┘           │ Hook (Uniswap v4)│                    │ (Observes &    │
                          │                  │                    │  Calculates)   │
                          │ • afterSwap      │                    └────────┬───────┘
                          │ • beforeAdd/     │                             │
                          │   Remove         │                             │
                          └────────▲─────────┘                             │
                                   │                                       │
                                   │      resolveEpisode(id, RSPE)        │
                                   └───────────────────────────────────────┘
                                             (After H blocks)

1. Every swap → Create episode (capture tick, liquidity, price)
2. LP adds liquidity → Open exposure segment (track who, when, where)
3. LP removes liquidity → Close segment
4. Reactive waits H blocks → Observes reference price → Calculates RSPE
5. Reactive calls back → Attribution distributes RSPE to exposed LPs
```

**Key Innovation:** **Episode-based model** enables asynchronous measurement (can't know if swap was arbitrage until observing future price).

---

## 🔗 Live Deployment

**Proof of Concept - 875+ Transactions on Testnet:**

- **Sepolia (Origin Chain)** - ExposureLedger Hook:  
  [`0x30D4F958F727518e4E5949538877065aBF924a40`](https://sepolia.etherscan.io/address/0x30D4F958F727518e4E5949538877065aBF924a40)

- **Reactive Lasna (Reactive Chain)** - Reactive Smart Contract:  
  [`0xe336AF67b6499F84839618BFC81aE9db4d582D91`](https://lasna.reactscan.net/address/0x1d2207f52782aaf69649a8c23eb9b9d83c2066ed/contract/0xe336af67b6499f84839618bfc81ae9db4d582d91?screen=rnk_transactions)

**On-Chain Attribution Proof:** 0.0003996 ETH MEV attributed across episodes (verified on Etherscan events).

---

## Key Concepts

### Episode
Immutable snapshot of a swap:
- Pool state (tick, sqrtPrice, liquidity)
- Amounts traded
- Direction (buy/sell token0)
- Timestamp (for manual fallback)

### Segment
LP exposure period:
- Range (tickLower, tickUpper)
- Liquidity amount
- Start episode ID (firstEpisodeId)
- End episode ID (lastEpisodeId, 0 = active)

### RSPE (Realized Stale-Price Externality)
```
D(e) = Stale opportunity (pool vs. reference at t=0)
A(e) = Adverse markout (pool vs. reference at t=H)

RSPE = min(D, A)  ← Conservative (never over-attributes noise)
```

### Attribution Formula
```
LP_share = (LP_liquidity / Active_liquidity) × RSPE
```

Proven sound: Sum of all LP shares = Total RSPE (conservation property)

---

```text
.
├── frontend/                           # React + Vite Frontend (MEV-Ray Vision Dashboard)
├── src/
│   ├── ExposureLedgerHook.sol          # Main Uniswap v4 hook
│   ├── ReactiveCallbackRelayer.sol     # Sepolia callback Relayer
│   ├── ILFlowRSC.sol                   # Base RSC abstraction
│   ├── reactive/
│   │   └── ExposureLedgerRSC.sol       # True Reactive Smart Contract (Event listener)
│   └── interfaces/
│       └── IExposureLedger.sol         # Hook interface
├── test/
│   ├── Phase3Test.t.sol                # Integration test entry point
│   ├── ExposureLedger*.t.sol           # Core test suites
│   └── mocks/                          # Mock PoolManagers & Routers
├── script/
│   ├── DeployRelayer.s.sol             # Deploy Relayer (Sepolia)
│   ├── DeployRSC.s.sol                 # Deploy RSC (Reactive Lasna)
│   ├── MineHookAddress.s.sol           # CREATE2 vanity address miner
│   └── E2ETestFlow.s.sol               # End-to-end full deployment test flow
├── .kiro/                              # Comprehensive documentation folder
├── lib/                                # Foundry dependencies
├── .env.example                        # Environment variables template
├── QUICKSTART.md                       # E2E Deployment and Startup Guide
└── README.md                           # This file
```

---

## Documentation

| Document | Description |
|----------|-------------|
| [RESEARCH.md](https://github.com/manashatwar/manashatwar-Exposure-Ledger-Exposure-Weighted-Realized-Externality-Ledger/blob/main/docs/RESEARCH.md) | Academic-grade specification with formal proofs, mathematical model, and literature review |
| [REQUIREMENTS.md](https://github.com/manashatwar/manashatwar-Exposure-Ledger-Exposure-Weighted-Realized-Externality-Ledger/blob/main/docs/REQUIREMENTS.md) | Functional requirements, invariants, acceptance criteria, security properties |
| [DESIGN.md](https://github.com/manashatwar/manashatwar-Exposure-Ledger-Exposure-Weighted-Realized-Externality-Ledger/blob/main/docs/DESIGN.md) | Technical design with state machines, complete Solidity interfaces, gas optimization |
| [ARCHITECTURE_VALIDATION.md](https://github.com/manashatwar/manashatwar-Exposure-Ledger-Exposure-Weighted-Realized-Externality-Ledger/blob/main/docs/ARCHITECTURE_VALIDATION.md) | 50-page validation that the architecture solves the problem (Score: 9/10) |



## Key Features

### ✅ Theoretically Sound
- Formal proofs of RSPE conservativeness (Theorem 3.1)
- Attribution soundness proven (Theorem 3.2)
- Builds on established LVR research (Milionis et al., 2022)

### ✅ Novel Contribution
- First protocol-native position-level MEV attribution
- No existing solution provides this granularity

### ✅ Practical Implementation
- Episode-based model handles async measurement correctly
- Segment tracking preserves historical exposure
- Manual fallback for Reactive Network failure

### ✅ Extensible Platform
Enables future features:
- MEV-adjusted fee redistribution
- LP risk scoring
- Dynamic fee mechanisms
- LP insurance/hedging products

---

## Technical Highlights

### Episode-Based Model
**Why:** Adverse selection is asynchronous (need future price data)

**Solution:** Decouple capture from resolution
- t=0: Create episode (synchronous, immutable)
- t=H: Resolve episode (async, calculate RSPE)
- Attribution: Distribute to exposed LPs

**This is the only viable architecture** for measuring adverse selection.

### Segment Tracking
**Why:** Can't reconstruct historical exposure from current state

**Solution:** Record exposure as it happens
- beforeAdd: Open segment (firstEpisodeId = now)
- beforeRemove: Close segment (lastEpisodeId = now - 1)
- Immutable history enables accurate attribution

### Conservative Attribution
**RSPE = min(D, A)** never over-attributes random noise
- Only counts realized adverse selection
- Proven conservative lower bound
- Defensible for first version

---

## MEV-Ray Vision Dashboard

Exposure Ledger includes a fully functional, highly polished React frontend called **MEV-Ray Vision**. 
It allows LPs to connect their wallet and visually explore their MEV exposure across their active liquidity segments.

**Key Dashboard Features:**
- **Position Explorer:** Query any LP address to see their segment history and per-episode MEV attribution.
- **MEV-Ray Vision:** Visual heatmap of active liquidity ranges colored by MEV intensity (adverse selection).
- **Cross-Chain Monitor:** Real-time pipeline tracking the lifecycle of an episode from Sepolia Hook to Lasna RSC.

### Running the Frontend
```bash
cd frontend
npm install
npm run dev
```

---

## Environment Setup

### Prerequisites
- Foundry (for Solidity development)
- Node.js (for frontend, optional)
- Access to Sepolia testnet
- Access to Reactive Network Lasna testnet

### Install Dependencies
```bash
# Clone repository
git clone https://github.com/manashatwar/manashatwar-Exposure-Ledger-Exposure-Weighted-Realized-Externality-Ledger.git
cd manashatwar-Exposure-Ledger-Exposure-Weighted-Realized-Externality-Ledger

# Install Foundry dependencies
forge install

# Build contracts (when implemented)
forge build

# Run tests (when implemented)
forge test
```

### Environment Variables
Create `.env` file:
```bash
DESTINATION_RPC=https://sepolia.infura.io/v3/YOUR_KEY
DESTINATION_PRIVATE_KEY=0x...
REACTIVE_RPC=https://lasna-rpc.rnk.dev/
REACTIVE_PRIVATE_KEY=0x...
DESTINATION_CALLBACK_PROXY_ADDR=0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA
```

---

## Deployment (Future)

Deployment steps will be added once implementation is complete.

---

## Research Foundation

### Academic References
1. **Milionis et al. (2022)**: Loss-versus-rebalancing (LVR) framework - [arXiv:2208.06046](https://arxiv.org/abs/2208.06046)
2. **Milionis & Adams (2023)**: FLAIR metric for LP competitiveness - [arXiv:2306.09421](https://arxiv.org/abs/2306.09421)
3. **JIT Liquidity Analysis**: Just-in-time liquidity attacks - [IACR ePrint 2023/973](https://eprint.iacr.org/2023/973)

### Key Insights from Research
- **Position-level matters**: FLAIR research proves LP competitiveness ≠ flow toxicity
- **LPs are losing money**: Empirical studies show insufficient fee compensation
- **JIT exists**: $750B in JIT volume (2024) proves sophisticated LPs optimize

**Conclusion:** Demand for position-level MEV measurement is validated by academic research and market behavior.

---

## FAQ

### Q: How is this different from Revert Finance / DeFi Llama?
**A:** Those show historical fees and IL but don't attribute MEV per position. Exposure Ledger measures realized adverse selection (MEV) using RSPE formula.

### Q: What's the difference from the old ILFlowHook?
**A:** 
- **ILFlowHook** = Insurance (LPs buy protection, underwriters provide collateral)
- **ExposureLedger** = Measurement (track MEV exposure, provide transparency)

Different goals, different models.

### Q: Why use Reactive Network?
**A:** MEV attribution requires observing future prices (asynchronous). Reactive enables automated callbacks after waiting H blocks. Manual fallback exists if Reactive fails.

### Q: Is RSPE = min(D, A) too conservative?
**A:** For v1, yes - it's intentionally conservative to avoid false positives. Future versions can add "optimistic" modes with empirical calibration.

### Q: What about gas costs?
**A:** Designed for O(N_exposed) attribution (typically <100 LPs), not O(N_LPs × N_segments). Pre-computed exposure lists keep costs manageable.

---

## Roadmap

### v1.0 (Current - 6 weeks)
- Core episode creation + segment tracking
- Reactive integration with manual fallback
- Basic attribution (single-tick approximation)
- Query interface for LP dashboard

### v2.0 (Future)
- Multi-tick path attribution (handle large swaps)
- Adaptive horizon (H varies with volatility)
- Multiple RSPE modes (conservative/optimistic)
- MEV-adjusted fee redistribution

### v3.0 (Long-term)
- Cross-pool correlated exposure tracking
- LP risk scoring system
- Real-time exposure estimation
- Integration with LP insurance products

---

## Contributing

This project is under active development. Contributions welcome after v1.0 implementation is complete.

---

## License

MIT License - see [LICENSE](LICENSE)

---

## Contact

- **GitHub:** [manashatwar/manashatwar-Exposure-Ledger-Exposure-Weighted-Realized-Externality-Ledger](https://github.com/manashatwar/manashatwar-Exposure-Ledger-Exposure-Weighted-Realized-Externality-Ledger)
- **Documentation:** [docs/](https://github.com/manashatwar/manashatwar-Exposure-Ledger-Exposure-Weighted-Realized-Externality-Ledger/tree/main/docs)

---

## Acknowledgments

- **Uniswap Labs** for v4 architecture
- **Reactive Network** for async callback infrastructure
- **Milionis et al.** for LVR and FLAIR research
- **Academic DeFi research community** for foundational work on AMM adverse selection

---

**Built with the goal of bringing transparency to LP MEV exposure** 🔍
