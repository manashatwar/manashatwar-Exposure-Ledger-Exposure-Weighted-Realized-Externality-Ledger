// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IExposureLedger
/// @notice Public interface for the ExposureLedgerHook contract.
///         Defines all structs, events, errors, and external functions used
///         by the Uniswap v4 hook and the Reactive Smart Contract (RSC).
interface IExposureLedger {
    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    /// @notice Immutable snapshot of pool state captured at swap time.
    ///         Created by afterSwap(), never modified after creation.
    /// @param episodeId      Sequential unique identifier (uint64 for packing)
    /// @param blockNumber    Block number at which the swap occurred
    /// @param tick           Post-swap active tick
    /// @param sqrtPriceX96   Post-swap sqrt price in Q64.96 format
    /// @param activeLiquidity Total liquidity active at the post-swap tick
    /// @param amount0        Signed token0 balance delta of the swap
    /// @param amount1        Signed token1 balance delta of the swap
    /// @param tradeDirection 0 = sold token0 into pool, 1 = bought token0 from pool
    /// @param externality    Resolved RSPE value (0 until resolved)
    /// @param resolved       True once resolveEpisode() or manualResolveEpisode() succeeds
    /// @param createdTimestamp Block timestamp at episode creation (for manual timeout)
    struct SwapEpisode {
        uint64 episodeId;
        uint64 blockNumber;
        int24 tick;
        uint160 sqrtPriceX96;
        uint128 activeLiquidity;
        int256 amount0;
        int256 amount1;
        uint8 tradeDirection;
        uint256 externality;
        bool resolved;
        uint256 createdTimestamp;
    }

    /// @notice Records an LP's exposure window — from the episode they added
    ///         liquidity to the episode they removed it.
    /// @param lp             Address of the liquidity provider
    /// @param tickLower      Lower tick bound of the position
    /// @param tickUpper      Upper tick bound of the position
    /// @param liquidity      Liquidity units contributed
    /// @param firstEpisodeId Episode at which exposure began (set on add)
    /// @param lastEpisodeId  Episode at which exposure ended (0 = still active)
    struct LPExposureSegment {
        address lp;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint64 firstEpisodeId;
        uint64 lastEpisodeId;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a new episode is created after a swap.
    /// @param episodeId       The newly assigned episode ID
    /// @param poolId          The Uniswap v4 pool identifier
    /// @param blockNumber     Block at which the swap happened
    /// @param tick            Post-swap active tick
    /// @param sqrtPriceX96    Post-swap price (Q64.96)
    /// @param activeLiquidity Total liquidity active at tick
    event EpisodeCreated(
        uint256 indexed episodeId,
        bytes32 indexed poolId,
        uint64 blockNumber,
        int24 tick,
        uint160 sqrtPriceX96,
        uint128 activeLiquidity
    );

    /// @notice Emitted when an episode is resolved with its RSPE externality value.
    /// @param episodeId  The episode being resolved
    /// @param externality The RSPE = min(staleOpportunity, adverseMarkout)
    /// @param timestamp  Block timestamp at resolution
    event EpisodeResolved(uint256 indexed episodeId, uint256 externality, uint256 timestamp);

    /// @notice Emitted for each LP that receives an attribution for an episode.
    /// @param lp        Address of the liquidity provider
    /// @param episodeId The episode they were exposed to
    /// @param amount    Attributed externality amount (liquidity-weighted share)
    event ExternalityAttributed(address indexed lp, uint256 indexed episodeId, uint256 amount);

    /// @notice Emitted when an LP opens a new exposure segment (adds liquidity).
    /// @param lp             LP address
    /// @param segmentIndex   Index into lpSegments[lp] array
    /// @param firstEpisodeId Episode at which exposure begins
    /// @param tickLower      Position lower tick
    /// @param tickUpper      Position upper tick
    /// @param liquidity      Liquidity amount
    event LPSegmentOpened(
        address indexed lp,
        uint256 segmentIndex,
        uint64 firstEpisodeId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );

    /// @notice Emitted when an LP closes their exposure segment (removes liquidity).
    /// @param lp            LP address
    /// @param segmentIndex  Index into lpSegments[lp] array
    /// @param lastEpisodeId Episode at which exposure ended
    event LPSegmentClosed(address indexed lp, uint256 segmentIndex, uint64 lastEpisodeId);

    /// @notice Emitted when the owner manually resolves a stuck episode after timeout.
    /// @param episodeId  The manually resolved episode
    /// @param externality Externality value set by owner
    /// @param proof      Arbitrary proof bytes provided by owner (off-chain evidence)
    event ManualResolution(uint256 indexed episodeId, uint256 externality, bytes proof);

    /// @notice Emitted when attribution is skipped because activeLiquidity == 0.
    /// @param episodeId The episode with zero active liquidity
    event ZeroLiquidityEpisode(uint256 indexed episodeId);

    // -------------------------------------------------------------------------
    // Custom Errors
    // -------------------------------------------------------------------------

    /// @notice Reverts when nextEpisodeId would overflow uint64.
    error EpisodeIdOverflow();

    /// @notice Reverts when resolveEpisode is called on an already-resolved episode.
    error EpisodeAlreadyResolved();

    /// @notice Reverts when msg.sender is not the authorised reactive callback proxy.
    error UnauthorizedResolver();

    /// @notice Reverts when getLPActiveSegment is called but no active segment exists.
    error NoActiveSegment();

    /// @notice Reverts when beforeRemoveLiquidity tick range doesn't match any active segment.
    error SegmentRangeMismatch();

    /// @notice Reverts when liquidityDelta is invalid (e.g. zero on add).
    error InvalidLiquidityDelta();

    /// @notice Reverts when attribution encounters zero active liquidity (division guard).
    error ZeroActiveLiquidity();

    /// @notice Reverts when manualResolveEpisode is called before the 7-day timeout.
    error ManualTimeoutNotReached();

    // -------------------------------------------------------------------------
    // Core External Functions
    // -------------------------------------------------------------------------

    /// @notice Called by the Reactive callback proxy to resolve an episode with its RSPE.
    /// @dev Only callable by reactiveCallbackProxy. Triggers _attributeExternality internally.
    /// @param episodeId  ID of the episode to resolve
    /// @param externality The RSPE value: min(staleOpportunity, adverseMarkout)
    function resolveEpisode(uint256 episodeId, uint256 externality) external;

    /// @notice Owner-only fallback resolution after 7-day timeout (if Reactive fails).
    /// @param episodeId  ID of the episode to resolve
    /// @param externality The externality value chosen by the owner
    /// @param proof      Arbitrary off-chain evidence bytes
    function manualResolveEpisode(uint256 episodeId, uint256 externality, bytes calldata proof) external;

    // -------------------------------------------------------------------------
    // Query Functions
    // -------------------------------------------------------------------------

    /// @notice Returns the total attributed externality accumulated by an LP across all episodes.
    function getLPTotalExternality(address lp) external view returns (uint256);

    /// @notice Returns the externality attributed to an LP for a specific episode.
    function getLPEpisodeAttribution(address lp, uint256 episodeId) external view returns (uint256);

    /// @notice Returns the full exposure segment history for an LP.
    function getLPSegments(address lp) external view returns (LPExposureSegment[] memory);

    /// @notice Returns the full SwapEpisode struct for a given episode ID.
    function getEpisode(uint256 episodeId) external view returns (SwapEpisode memory);

    /// @notice Returns the currently active segment for an LP, reverts if none.
    function getLPActiveSegment(address lp) external view returns (LPExposureSegment memory);

    // -------------------------------------------------------------------------
    // Admin Functions
    // -------------------------------------------------------------------------

    /// @notice Sets the Reactive callback proxy address. One-time, owner-only.
    /// @param proxy Address of the Reactive system contract that will call resolveEpisode
    function setReactiveCallbackProxy(address proxy) external;
}
