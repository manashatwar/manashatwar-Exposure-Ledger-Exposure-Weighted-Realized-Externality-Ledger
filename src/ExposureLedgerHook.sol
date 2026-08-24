// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ---------------------------------------------------------------------------
// Uniswap v4 core imports
// ---------------------------------------------------------------------------
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

// ---------------------------------------------------------------------------
// OpenZeppelin
// ---------------------------------------------------------------------------
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// ---------------------------------------------------------------------------
// Local interface
// ---------------------------------------------------------------------------
import {IExposureLedger} from "./interfaces/IExposureLedger.sol";

/// @title ExposureLedgerHook
/// @notice Uniswap v4 hook that implements position-level MEV attribution.
///
///   Architecture Overview
///   ─────────────────────
///   • afterSwap         → creates an immutable SwapEpisode (snapshot of pool state)
///   • beforeAddLiquidity → opens an LPExposureSegment (starts tracking exposure)
///   • beforeRemoveLiquidity → closes the matching segment (stops tracking)
///   • resolveEpisode    → called by Reactive Network after H blocks; stores RSPE
///                          and distributes externality to exposed LPs
///   • manualResolveEpisode → owner-only fallback after 7-day timeout
///
///   Mathematical Foundation
///   ───────────────────────
///   episodeExternality = min(staleOpportunity, adverseMarkout)   (RSPE formula)
///   lpAttribution      = episodeExternality × (lpLiquidity / activeLiquidity)
///
/// @dev Inherits BaseHook (Uniswap v4 hook base) and Ownable (access control).
///      All insurance-model code from ILFlowHook.sol has been removed.
contract ExposureLedgerHook is BaseHook, Ownable, IExposureLedger {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // =========================================================================
    // Task 1.2 — Data Structures & Storage
    // =========================================================================

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Observation horizon: number of blocks the RSC waits before
    ///         querying the reference oracle and resolving the episode.
    ///         50 blocks ≈ 10 minutes on Ethereum mainnet.
    uint256 public constant OBSERVATION_HORIZON = 50;

    /// @notice After this timeout the owner may manually resolve an episode
    ///         if the Reactive Network has failed to do so automatically.
    uint256 public constant MANUAL_RESOLUTION_TIMEOUT = 7 days;

    /// @notice Fixed-point precision used in liquidity-share calculations.
    ///         Using 1e18 keeps rounding errors below 1 wei.
    uint256 public constant PRECISION = 1e18;

    // -------------------------------------------------------------------------
    // Episode storage
    // -------------------------------------------------------------------------

    /// @notice All swap episodes, keyed by sequential ID.
    ///         Episodes are IMMUTABLE after creation — no field may be overwritten
    ///         except `externality` and `resolved`, which are set once by resolution.
    mapping(uint256 => SwapEpisode) public episodes;

    /// @notice Monotonically increasing counter; also represents the *next* episode
    ///         that will be created on the next swap.
    uint256 public nextEpisodeId;

    // -------------------------------------------------------------------------
    // LP segment storage
    // -------------------------------------------------------------------------

    /// @notice Full exposure segment history for every LP.
    ///         New segments are appended; closed segments have lastEpisodeId > 0.
    mapping(address => LPExposureSegment[]) public lpSegments;

    // -------------------------------------------------------------------------
    // Attribution storage
    // -------------------------------------------------------------------------

    /// @notice Cumulative externality attributed to each LP across all episodes.
    ///         This is the primary "MEV cost" metric surfaced to LPs.
    mapping(address => uint256) public lpTotalExternality;

    /// @notice Per-LP, per-episode attribution for granular historical queries.
    mapping(address => mapping(uint256 => uint256)) public lpEpisodeAttribution;

    /// @notice Pre-computed list of LP addresses exposed in each episode.
    ///         Built during beforeAddLiquidity / beforeRemoveLiquidity so that
    ///         attribution iterates only O(N_exposed) LPs, not all LPs.
    mapping(uint256 => address[]) public episodeExposedLPs;

    // -------------------------------------------------------------------------
    // Access control
    // -------------------------------------------------------------------------

    /// @notice The Reactive Network proxy address authorised to call resolveEpisode().
    ///         Set once via setReactiveCallbackProxy(); cannot be changed afterwards.
    address public reactiveCallbackProxy;

    // =========================================================================
    // Task 4.2 — Active LP Registry (for O(N_exposed) attribution)
    // =========================================================================

    /// @notice Ordered list of every LP address that has ever added liquidity.
    ///         Used by _afterSwap to enumerate potential exposures per episode.
    /// @dev    Slot 8. We never remove addresses: stale entries are filtered
    ///         by _getActiveSegmentAt returning liquidity == 0.
    address[] internal _activeLPList;

    /// @notice Deduplication guard so each LP appears at most once in _activeLPList.
    /// @dev    Slot 9.
    mapping(address => bool) internal _activeLPRegistered;

    // =========================================================================
    // Task 1.3 — Events  (declared in IExposureLedger, re-referenced here for docs)
    // =========================================================================
    //
    // event EpisodeCreated(uint256 indexed episodeId, bytes32 indexed poolId, ...)
    // event EpisodeResolved(uint256 indexed episodeId, uint256 externality, uint256 timestamp)
    // event ExternalityAttributed(address indexed lp, uint256 indexed episodeId, uint256 amount)
    // event LPSegmentOpened(address indexed lp, uint256 segmentIndex, ...)
    // event LPSegmentClosed(address indexed lp, uint256 segmentIndex, uint64 lastEpisodeId)
    // event ManualResolution(uint256 indexed episodeId, uint256 externality, bytes proof)
    // event ZeroLiquidityEpisode(uint256 indexed episodeId)
    //
    // (All events are inherited from the IExposureLedger interface.)

    // =========================================================================
    // Task 1.4 — Custom Errors  (declared in IExposureLedger, re-referenced here)
    // =========================================================================
    //
    // error EpisodeIdOverflow()
    // error EpisodeAlreadyResolved()
    // error UnauthorizedResolver()
    // error NoActiveSegment()
    // error SegmentRangeMismatch()
    // error InvalidLiquidityDelta()
    // error ZeroActiveLiquidity()
    // error ManualTimeoutNotReached()
    //
    // (All errors are inherited from the IExposureLedger interface.)

    // =========================================================================
    // Task 1.1 — Constructor & Hook Permissions
    // =========================================================================

    /// @param _poolManager Uniswap v4 PoolManager singleton address.
    /// @param _poolManager  Uniswap v4 PoolManager address.
    /// @param initialOwner  Address that will own this contract.
    ///                      Must be passed explicitly because when deployed via the
    ///                      Nick/CREATE2 factory, msg.sender is the factory, not
    ///                      the deployer wallet.
    constructor(IPoolManager _poolManager, address initialOwner)
        BaseHook(_poolManager)
        Ownable(initialOwner)
    {}


    /// @inheritdoc BaseHook
    /// @notice Declares the three hook points this contract handles:
    ///         • afterSwap         — episode creation
    ///         • beforeAddLiquidity  — segment open
    ///         • beforeRemoveLiquidity — segment close
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /// @notice Sets (or updates) the Reactive callback proxy. Owner-only.
    /// @param proxy Address of the Reactive RSC contract.
    function setReactiveCallbackProxy(address proxy) external onlyOwner {
        require(proxy != address(0), "Proxy cannot be zero address");
        reactiveCallbackProxy = proxy;
    }

    // =========================================================================
    // Hook Implementations  (Phase 2 — stubs for now, implemented in Phase 2-4)
    // =========================================================================

    /// @dev afterSwap: creates an immutable episode. Implemented in Task 2.1.
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Task 2.1 implementation goes here
        // -----------------------------------
        // Guard: episode ID overflow
        if (nextEpisodeId >= type(uint64).max) revert EpisodeIdOverflow();

        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        uint128 activeLiquidity = poolManager.getLiquidity(poolId);

        // Determine trade direction: amount0 < 0 means token0 was sold into pool
        uint8 direction = delta.amount0() < 0 ? 0 : 1;

        uint256 episodeId = nextEpisodeId;

        episodes[episodeId] = SwapEpisode({
            episodeId: uint64(episodeId),
            blockNumber: uint64(block.number),
            tick: tick,
            sqrtPriceX96: sqrtPriceX96,
            activeLiquidity: activeLiquidity,
            amount0: delta.amount0(),
            amount1: delta.amount1(),
            tradeDirection: direction,
            externality: 0,
            resolved: false,
            createdTimestamp: block.timestamp
        });

        emit EpisodeCreated(episodeId, PoolId.unwrap(poolId), uint64(block.number), tick, sqrtPriceX96, activeLiquidity);

        // Task 4.2 — Pre-compute exposed LPs for this episode.
        _populateExposedLPs(episodeId, tick);

        // unchecked: overflow guard is the revert above (nextEpisodeId < type(uint64).max)
        unchecked { nextEpisodeId++; }

        return (BaseHook.afterSwap.selector, 0);
    }

    /// @dev beforeAddLiquidity: opens an LP exposure segment. Implemented in Task 2.2.
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        // Skip if not adding liquidity (delta must be positive)
        if (params.liquidityDelta <= 0) {
            return BaseHook.beforeAddLiquidity.selector;
        }

        LPExposureSegment memory segment = LPExposureSegment({
            lp: sender,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: uint128(uint256(params.liquidityDelta)),
            firstEpisodeId: uint64(nextEpisodeId),
            lastEpisodeId: type(uint64).max // sentinel: max = active, any other value = closed
        });

        lpSegments[sender].push(segment);

        // Task 4.2 — Register this LP in the active LP list (once per address).
        if (!_activeLPRegistered[sender]) {
            _activeLPRegistered[sender] = true;
            _activeLPList.push(sender);
        }

        uint256 segmentIndex = lpSegments[sender].length - 1;

        emit LPSegmentOpened(
            sender,
            segmentIndex,
            segment.firstEpisodeId,
            segment.tickLower,
            segment.tickUpper,
            segment.liquidity
        );

        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @dev beforeRemoveLiquidity: closes the matching LP segment. Implemented in Task 2.3.
    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        // Skip if liquidityDelta is not negative (not a removal)
        if (params.liquidityDelta >= 0) {
            return BaseHook.beforeRemoveLiquidity.selector;
        }

        LPExposureSegment[] storage segments = lpSegments[sender];

        for (uint256 i = 0; i < segments.length; i++) {
            if (
                segments[i].lastEpisodeId == type(uint64).max // Active sentinel
                    && segments[i].tickLower == params.tickLower && segments[i].tickUpper == params.tickUpper
            ) {
                // Close the segment: exposure ends at the episode BEFORE this one
                uint64 lastEpisodeId = nextEpisodeId > 0 ? uint64(nextEpisodeId - 1) : 0;
                segments[i].lastEpisodeId = lastEpisodeId;

                emit LPSegmentClosed(sender, i, lastEpisodeId);
                break;
            }
        }

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // =========================================================================
    // Resolution (Phase 3 — Task 3.2 & 3.3)
    // =========================================================================

    /// @inheritdoc IExposureLedger
    /// @notice Receives the RSPE externality value from the Reactive Network
    ///         and distributes it proportionally to exposed LPs.
    function resolveEpisode(uint256 episodeId, uint256 externality) external {
        if (msg.sender != reactiveCallbackProxy) revert UnauthorizedResolver();

        SwapEpisode storage episode = episodes[episodeId];
        if (episode.resolved) revert EpisodeAlreadyResolved();

        episode.externality = externality;
        episode.resolved = true;

        emit EpisodeResolved(episodeId, externality, block.timestamp);

        _attributeExternality(episodeId);
    }

    /// @inheritdoc IExposureLedger
    /// @notice Owner-only manual resolution after MANUAL_RESOLUTION_TIMEOUT.
    function manualResolveEpisode(uint256 episodeId, uint256 externality, bytes calldata proof) external onlyOwner {
        SwapEpisode storage episode = episodes[episodeId];

        if (episode.resolved) revert EpisodeAlreadyResolved();
        if (block.timestamp < episode.createdTimestamp + MANUAL_RESOLUTION_TIMEOUT) {
            revert ManualTimeoutNotReached();
        }

        episode.externality = externality;
        episode.resolved = true;

        emit EpisodeResolved(episodeId, externality, block.timestamp);
        emit ManualResolution(episodeId, externality, proof);

        _attributeExternality(episodeId);
    }

    // =========================================================================
    // Attribution (Phase 4 — Task 4.1)
    // =========================================================================

    /// @notice Distributes episode externality to all LPs that were exposed.
    ///         Attribution = externality × (lpLiquidity / activeLiquidity).
    /// @dev Zero externality or zero liquidity episodes are handled safely.
    /// @param episodeId The episode to attribute.
    function _attributeExternality(uint256 episodeId) internal {
        SwapEpisode storage episode = episodes[episodeId];

        // Nothing to distribute
        if (episode.externality == 0) return;

        // Guard against division by zero in share calculation
        if (episode.activeLiquidity == 0) {
            emit ZeroLiquidityEpisode(episodeId);
            return;
        }

        address[] memory exposedLPs = episodeExposedLPs[episodeId];

        // Cache storage reads once — avoids repeated SLOADs per LP
        uint256 totalExternality  = episode.externality;
        uint256 totalLiquidity    = uint256(episode.activeLiquidity);

        for (uint256 i = 0; i < exposedLPs.length; i++) {
            address lp = exposedLPs[i];

            LPExposureSegment memory segment = _getActiveSegmentAt(lp, episodeId);
            if (segment.liquidity == 0) continue;

            // Proportional share — unchecked is safe:
            //   segment.liquidity <= activeLiquidity  → share <= PRECISION (no overflow)
            //   externality * share <= type(uint256).max  (share <= 1e18, externality checked by Solidity)
            uint256 exposureShare;
            uint256 attribution;
            unchecked {
                exposureShare = (uint256(segment.liquidity) * PRECISION) / totalLiquidity;
                attribution   = (totalExternality * exposureShare) / PRECISION;
            }

            lpTotalExternality[lp]          += attribution;
            lpEpisodeAttribution[lp][episodeId] = attribution;

            emit ExternalityAttributed(lp, episodeId, attribution);
        }
    }

    // =========================================================================
    // Task 4.2 — Exposed LP Pre-computation
    // =========================================================================

    /// @notice Populates episodeExposedLPs[episodeId] at the moment of episode
    ///         creation by checking which registered LPs have an active segment
    ///         whose tick range spans the swap tick.
    ///
    /// @dev Complexity: O(N_LPs × N_segments_per_LP). For a reasonable pool with
    ///      hundreds of distinct LPs and small segment history this is acceptable.
    ///      For extremely large LP sets, move to an off-chain keeper pattern.
    ///
    /// @param episodeId  Newly created episode.
    /// @param swapTick   Current tick at the moment of the swap.
    function _populateExposedLPs(uint256 episodeId, int24 swapTick) internal {
        uint256 len = _activeLPList.length;
        for (uint256 i = 0; i < len; i++) {
            address lp = _activeLPList[i];
            LPExposureSegment[] storage segs = lpSegments[lp];

            // Check all segments — an LP may have multiple open positions
            for (uint256 j = 0; j < segs.length; j++) {
                if (
                    segs[j].lastEpisodeId == type(uint64).max && // active sentinel
                    _isExposed(segs[j].tickLower, segs[j].tickUpper, swapTick)
                ) {
                    episodeExposedLPs[episodeId].push(lp);
                    break; // count each LP once per episode
                }
            }
        }
    }

    /// @notice Returns true if a tick range is active at the given swap tick.
    /// @dev A Uniswap v4 position earns fees when tickLower <= currentTick < tickUpper.
    /// @param tickLower  Lower bound of the LP range (inclusive).
    /// @param tickUpper  Upper bound of the LP range (exclusive).
    /// @param swapTick   The tick at the time of the swap.
    function _isExposed(int24 tickLower, int24 tickUpper, int24 swapTick)
        internal
        pure
        returns (bool)
    {
        return tickLower <= swapTick && swapTick < tickUpper;
    }

    /// @notice Returns the number of registered LPs (useful for gas estimation).
    function activeLPCount() external view returns (uint256) {
        return _activeLPList.length;
    }

    /// @notice Returns the list of LPs registered for exposure tracking.
    function getActiveLPList() external view returns (address[] memory) {
        return _activeLPList;
    }

    /// @notice Returns the list of LP addresses exposed during a given episode.
    function getEpisodeExposedLPs(uint256 episodeId) external view returns (address[] memory) {
        return episodeExposedLPs[episodeId];
    }

    /// @notice Returns the number of LPs exposed in a given episode.
    function episodeExposedLPCount(uint256 episodeId) external view returns (uint256) {
        return episodeExposedLPs[episodeId].length;
    }
    /// @notice Returns the segment that was active for an LP at a given episode.
    ///         Returns an empty segment (liquidity == 0) if not found.
    function _getActiveSegmentAt(address lp, uint256 episodeId)
        internal
        view
        returns (LPExposureSegment memory)
    {
        LPExposureSegment[] storage segs = lpSegments[lp];

        for (uint256 i = 0; i < segs.length; i++) {
            bool started  = segs[i].firstEpisodeId <= episodeId;
            // active sentinel (type(uint64).max) means the segment is still open
            bool notEnded = segs[i].lastEpisodeId == type(uint64).max
                         || segs[i].lastEpisodeId >= episodeId;

            if (started && notEnded) {
                return segs[i];
            }
        }

        // Return empty sentinel
        return LPExposureSegment({lp: address(0), tickLower: 0, tickUpper: 0, liquidity: 0, firstEpisodeId: 0, lastEpisodeId: 0});
    }

    // =========================================================================
    // Query Functions (Phase 5 — Task 5.1)
    // =========================================================================

    /// @inheritdoc IExposureLedger
    function getLPTotalExternality(address lp) external view returns (uint256) {
        return lpTotalExternality[lp];
    }

    /// @inheritdoc IExposureLedger
    function getLPEpisodeAttribution(address lp, uint256 episodeId) external view returns (uint256) {
        return lpEpisodeAttribution[lp][episodeId];
    }

    /// @inheritdoc IExposureLedger
    function getLPSegments(address lp) external view returns (LPExposureSegment[] memory) {
        return lpSegments[lp];
    }

    /// @inheritdoc IExposureLedger
    function getEpisode(uint256 episodeId) external view returns (SwapEpisode memory) {
        return episodes[episodeId];
    }

    /// @inheritdoc IExposureLedger
    /// @notice Reverts with NoActiveSegment if the LP has no open position.
    function getLPActiveSegment(address lp) external view returns (LPExposureSegment memory) {
        LPExposureSegment[] storage segs = lpSegments[lp];
        for (uint256 i = 0; i < segs.length; i++) {
            if (segs[i].lastEpisodeId == type(uint64).max) { // active sentinel
                return segs[i];
            }
        }
        revert NoActiveSegment();
    }
}
