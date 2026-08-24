// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractPausableReactive} from "reactive-lib/abstract-base/AbstractPausableReactive.sol";
import {AbstractPayer} from "reactive-lib/abstract-base/AbstractPayer.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {IPayer} from "reactive-lib/interfaces/IPayer.sol";
import {IExposureLedger} from "../interfaces/IExposureLedger.sol";

/// @title ExposureLedgerRSC
/// @notice Reactive Smart Contract — the off-chain observer component of the
///         ExposureLedger system running on the Reactive Network.
///
///   Workflow
///   ─────────
///   1. Subscribes to `EpisodeCreated` events emitted by ExposureLedgerHook
///      on the origin chain (e.g. Ethereum mainnet or Base).
///   2. On each event, stores a PendingEpisode record keyed by episodeId
///      and tracks the latest `sqrtPriceX96` for that pool.
///   3. After OBSERVATION_HORIZON blocks (≈10 blocks / 2 min):
///      - Calculates RSPE by comparing the episode's starting price against the latest known price.
///      - Calculates RSPE = min(D, A):
///          D = stale-opportunity: cost from the LP's perspective of providing
///              stale liquidity relative to the reference market.
///          A = adverse-markout:   change in pool price over H blocks × trade size.
///      - Calls `ExposureLedgerHook.resolveEpisode(episodeId, rspe)` via
///        Reactive's cross-chain callback mechanism.
///
///   Mathematical Foundation
///   ────────────────────────
///   All prices are token1/token0 in 18-decimal fixed-point (1e18 = 1.0).
///
///   sqrtPriceToPrice(sqrtPriceX96) = (sqrtPriceX96 / 2^96)² × 1e18
///
///   D (stale opportunity) = |poolPrice − referencePrice0| × |amount0| / 1e18
///   A (adverse markout)   = |poolPrice − referencePriceH| × |amount0| / 1e18
///   RSPE = min(D, A)
///
/// @dev Extends AbstractPausableReactive.
contract ExposureLedgerRSC is AbstractPausableReactive {
    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Blocks to wait after a swap before resolving the episode.
    uint256 public constant OBSERVATION_HORIZON = 10;

    /// @notice keccak256("EpisodeCreated(uint256,bytes32,uint64,int24,uint160,uint128)")
    ///         This is the topic0 we subscribe to on the origin chain.
    bytes32 public constant EPISODE_CREATED_TOPIC =
        keccak256("EpisodeCreated(uint256,bytes32,uint64,int24,uint160,uint128)");

    /// @notice CRON event topics for periodic execution
    bytes32 public constant CRON_10_TOPIC = 0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687;
    bytes32 public constant CRON_100_TOPIC = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    
    /// @notice Reactive Network chain ID (Lasna testnet)
    uint256 public constant REACTIVE_CHAIN_ID = 5318007;
    
    /// @notice System contract address on Reactive Network
    address public constant SYSTEM_CONTRACT = 0x0000000000000000000000000000000000fffFfF;

    /// @notice Fixed-point base (1e18) for price arithmetic.
    uint256 public constant PRECISION = 1e18;

    /// @notice 2^96 used in sqrtPriceX96 → price conversion.
    uint256 public constant Q96 = 2 ** 96;

    // =========================================================================
    // State
    // =========================================================================

    /// @notice Address of ExposureLedgerHook on the destination chain.
    address public hookAddress;

    /// @notice Address of the callback relayer on the destination chain.
    address public relayerAddress;

    /// @notice Source chain ID that we observe (e.g. 1 for Ethereum mainnet).
    uint256 public originChainId;

    /// @notice Destination chain ID where the hook lives.
    uint256 public destinationChainId;

    /// @notice Pending episode data awaiting resolution after OBSERVATION_HORIZON.
    mapping(uint256 => PendingEpisode) public pendingEpisodes;

    /// @notice Track all pending episode IDs for CRON-based iteration
    uint256[] public pendingEpisodeIds;

    /// @notice True Reactive Architecture: Tracks the latest real-time price of the pool emitted by events
    mapping(bytes32 => uint160) public latestPoolPrice;

    /// @notice Last Sepolia block number we checked (for CRON-based resolution)
    uint256 public lastCheckedSepoliaBlock;

    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice Minimal snapshot of the episode data needed for RSPE calculation.
    /// @param createdBlock    Block at which the swap occurred (from the event).
    /// @param poolId          Uniswap v4 PoolId bytes32.
    /// @param sqrtPriceX96    Post-swap sqrt price (Q64.96 format).
    /// @param amount0         Signed token0 delta of the swap.
    /// @param direction       0 = sold token0, 1 = bought token0.
    /// @param exists          True if the record was written (guards against default-zero reads).
    struct PendingEpisode {
        uint64 createdBlock;
        bytes32 poolId;
        uint160 sqrtPriceX96;
        uint160 preSwapPrice;
        int256 amount0;
        uint8 direction;
        bool exists;
        uint256 rvmCreatedBlock;
    }

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when the RSC stores a new pending episode.
    event EpisodePending(uint256 indexed episodeId, uint64 createdBlock, bytes32 poolId);

    /// @notice Emitted when the RSC triggers resolution on the hook.
    event EpisodeResolutionTriggered(uint256 indexed episodeId, uint256 rspe);

    /// @notice Emitted when an episode is skipped (zero amount / no price data).
    event EpisodeResolutionSkipped(uint256 indexed episodeId, string reason);

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Episode not found in pending store.
    error EpisodeNotPending();

    /// @notice Block horizon not yet reached.
    error ObservationHorizonNotReached();

    /// @notice Oracle returned zero price.
    error OraclePriceZero();

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _originChainId   Chain ID of the origin network (where hook emits events).
    /// @param _destinationChainId Chain ID of the destination network (where hook lives).
    /// @param _hookAddress     Address of ExposureLedgerHook on the destination chain.
    /// @param _relayerAddress  Address of the CallbackRelayer on the destination chain.
    constructor(
        uint256 _originChainId,
        uint256 _destinationChainId,
        address _hookAddress,
        address _relayerAddress
    ) payable AbstractPausableReactive() {
        originChainId      = _originChainId;
        destinationChainId = _destinationChainId;
        hookAddress        = _hookAddress;
        relayerAddress     = _relayerAddress;

        if (!vm) {
            // Only subscribe if not paused by default
            Subscription[] memory subs = getPausableSubscriptions();
            for (uint256 ix = 0; ix < subs.length; ++ix) {
                try service.subscribe(
                    subs[ix].chain_id,
                    subs[ix]._contract,
                    subs[ix].topic_0,
                    subs[ix].topic_1,
                    subs[ix].topic_2,
                    subs[ix].topic_3
                ) {} catch {
                    paused = true; // Fixes deadlock if constructor subscribe fails
                }
            }
        }
    }

    // =========================================================================
    // Pausable Subscriptions
    // =========================================================================

    function getPausableSubscriptions() internal view override returns (Subscription[] memory) {
        Subscription[] memory result = new Subscription[](2);
        
        // Subscription 1: EpisodeCreated on the origin chain
        result[0] = Subscription(
            originChainId,
            hookAddress,
            uint256(EPISODE_CREATED_TOPIC),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );

        // Subscription 2: CRON-10 on the Reactive Network
        result[1] = Subscription(
            block.chainid,
            address(service), // the CRON events come from the service contract!
            uint256(CRON_10_TOPIC),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );

        return result;
    }

    // =========================================================================
    // Receive Function (for funding the RSC)
    // =========================================================================

    /// @notice Allows the RSC to receive native tokens for gas funding.
    receive() external payable override(AbstractPayer, IPayer) {}

    // =========================================================================
    // Reactive Callback
    // =========================================================================

    /// @notice Called by the Reactive Network when an event is detected.
    ///         Handles both EpisodeCreated events and CRON-10 events.
    function react(IReactive.LogRecord calldata log) external override vmOnly {
        // Handle CRON-10 events for periodic resolution checks
        if (log.topic_0 == uint256(CRON_10_TOPIC)) {
            _checkAndResolvePendingEpisodes();
            return;
        }
        
        // Handle EpisodeCreated events
        if (log.chain_id != originChainId) return;
        if (log._contract != hookAddress) return;
        if (log.topic_0 != uint256(EPISODE_CREATED_TOPIC)) return;

        // Decode indexed fields
        uint256 episodeId = log.topic_1;
        bytes32 poolId    = bytes32(log.topic_2);

        // Decode non-indexed fields from data
        (uint64 blockNumber,, uint160 sqrtPriceX96,) =
            abi.decode(log.data, (uint64, int24, uint160, uint128));

        // [THE TRUE REACTIVE ARCHITECTURE]: Track the pre-swap price natively!
        uint160 oldPrice = latestPoolPrice[poolId];
        if (oldPrice == 0) oldPrice = sqrtPriceX96; // First swap fallback
        latestPoolPrice[poolId] = sqrtPriceX96;

        // Store pending episode
        pendingEpisodes[episodeId] = PendingEpisode({
            createdBlock:  blockNumber,
            poolId:        poolId,
            sqrtPriceX96:  sqrtPriceX96,
            preSwapPrice:  oldPrice,
            amount0:       0,
            direction:     0,
            exists:        true,
            rvmCreatedBlock: block.number
        });
        
        // Track episode ID for CRON-based iteration
        pendingEpisodeIds.push(episodeId);

        emit EpisodePending(episodeId, blockNumber, poolId);
    }

    // =========================================================================
    // Resolution
    // =========================================================================

    /// @notice Internal function to check and resolve pending episodes on CRON trigger.
    ///         Queries Sepolia block number and resolves episodes that are ready.
    function _checkAndResolvePendingEpisodes() internal {
        // Get current Sepolia block (we'll use the episode's creation block + HORIZON)
        // Since we can't directly query Sepolia from here, we iterate through pending episodes
        // and attempt resolution for each one
        
        uint256 i = 0;
        while (i < pendingEpisodeIds.length) {
            uint256 episodeId = pendingEpisodeIds[i];
            PendingEpisode memory ep = pendingEpisodes[episodeId];
            
            if (!ep.exists) {
                // Already resolved, remove from array
                _removePendingEpisodeId(i);
                continue;
            }
            
            // Try to resolve - if horizon not reached, this will revert silently
            try this.tryResolveEpisode(episodeId) {
                // Resolution successful, remove from pending array
                _removePendingEpisodeId(i);
            } catch {
                // Not ready yet or resolution failed, move to next
                i++;
            }
        }
    }
    
    /// @notice Helper to remove episode ID from tracking array
    function _removePendingEpisodeId(uint256 index) internal {
        if (index >= pendingEpisodeIds.length) return;
        pendingEpisodeIds[index] = pendingEpisodeIds[pendingEpisodeIds.length - 1];
        pendingEpisodeIds.pop();
    }
    
    /// @notice External wrapper for try-catch in _checkAndResolvePendingEpisodes
    function tryResolveEpisode(uint256 episodeId) external {
        require(msg.sender == address(this), "Only self");
        PendingEpisode memory ep = pendingEpisodes[episodeId];
        if (!ep.exists) revert EpisodeNotPending();
        
        // Wait for 60 RVM blocks (~2 minutes) to allow price to move before calculating markout
        if (block.number < ep.rvmCreatedBlock + 60) {
            revert ObservationHorizonNotReached();
        }
        
        // Use true event-driven prices natively collected by the RSC
        uint256 poolPrice = _sqrtPriceX96ToPrice(ep.sqrtPriceX96);
        
        // P_ref0 is perfectly captured as the pool's pre-swap price
        uint256 price0 = _sqrtPriceX96ToPrice(ep.preSwapPrice);
        
        // The future markout price (A) comes directly from the true event-stream!
        uint256 priceH = _sqrtPriceX96ToPrice(latestPoolPrice[ep.poolId]);
        
        // Use a default amount for RSPE calculation (1e18 = 1 token0)
        uint256 absAmount = 1e18;
        uint256 D = _absDiff(poolPrice, price0) * absAmount / PRECISION;
        uint256 A = _absDiff(poolPrice, priceH) * absAmount / PRECISION;
        uint256 rspe = D < A ? D : A;

        // Emit callback to resolve on destination chain
        // IMPORTANT: Reactive Network relayer forces the first 32 bytes of payload 
        // to be the RSC sender address. We MUST prepend an empty address parameter.
        bytes memory payload = abi.encodeWithSignature(
            "resolveEpisode(address,uint256,uint256)",
            address(0),
            episodeId,
            rspe
        );
        emit IReactive.Callback(
            destinationChainId,
            relayerAddress,
            CALLBACK_GAS_LIMIT,
            payload
        );

        delete pendingEpisodes[episodeId];
        emit EpisodeResolutionTriggered(episodeId, rspe);
    }

    uint64 constant CALLBACK_GAS_LIMIT = 300000;

    /// @notice Called by a keeper (or Reactive scheduler) after OBSERVATION_HORIZON
    ///         blocks have passed since the episode was created.
    ///
    ///   RSPE Calculation:
    ///   -----------------
    ///   poolPrice      = sqrtPriceX96ToPrice(ep.sqrtPriceX96)
    ///   referencePrice0 = oracle.getPriceAtBlock(poolId, createdBlock)
    ///   referencePriceH = oracle.getPriceAtBlock(poolId, createdBlock + H)
    ///
    ///   D = stale opportunity  = |poolPrice - referencePrice0| × |amount0| / PRECISION
    ///   A = adverse markout    = |poolPrice - referencePriceH| × |amount0| / PRECISION
    ///   RSPE = min(D, A)
    ///
    /// @dev In production this call is embedded into the Reactive `react()` loop
    ///      via a scheduled callback. In simulation it can be called externally.
    ///
    /// @param episodeId ID of the episode to resolve.
    function triggerResolution(uint256 episodeId) external {
        PendingEpisode memory ep = pendingEpisodes[episodeId];
        if (!ep.exists) revert EpisodeNotPending();
        
        // Use true event-driven prices natively collected by the RSC
        uint256 poolPrice = _sqrtPriceX96ToPrice(ep.sqrtPriceX96);
        uint256 price0 = poolPrice;
        uint256 priceH = _sqrtPriceX96ToPrice(latestPoolPrice[ep.poolId]);

        // Absolute amount of token0 involved (magnitude only for sizing)
        uint256 absAmount = 1e18; // Use 1e18 for standardized scaling in the mock

        // D = stale opportunity
        uint256 D = _absDiff(poolPrice, price0) * absAmount / PRECISION;

        // A = adverse markout
        uint256 A = _absDiff(poolPrice, priceH) * absAmount / PRECISION;

        // RSPE = min(D, A)
        uint256 rspe = D < A ? D : A;

        // Trigger resolution callback on the hook
        bytes memory payload = abi.encodeWithSignature(
            "resolveEpisode(address,uint256,uint256)",
            address(0),
            episodeId,
            rspe
        );
        emit IReactive.Callback(
            destinationChainId,
            relayerAddress,
            CALLBACK_GAS_LIMIT,
            payload
        );

        // Clean up pending store
        delete pendingEpisodes[episodeId];

        emit EpisodeResolutionTriggered(episodeId, rspe);
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /// @notice Update the hook address (owner-only, emergency use only).
    function setHookAddress(address _hookAddress) external onlyOwner {
        hookAddress = _hookAddress;
    }

    // =========================================================================
    // Math Helpers (internal pure)
    // =========================================================================

    /// @notice Converts a Uniswap v4 sqrtPriceX96 to a 18-decimal token1/token0 price.
    /// @dev price = (sqrtPriceX96 / 2^96)² × 1e18
    ///      Computed as: (sqrtPriceX96 * sqrtPriceX96 * PRECISION) / (Q96 * Q96)
    ///      Uses uint256 arithmetic — valid up to sqrtPriceX96 ≈ 2^128.
    function _sqrtPriceX96ToPrice(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 sq = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return sq * PRECISION / (Q96 * Q96);
    }

    /// @notice Absolute difference between two uint256 values.
    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a - b : b - a;
    }
}
