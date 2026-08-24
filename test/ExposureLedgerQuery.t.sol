// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ExposureLedgerHook} from "../src/ExposureLedgerHook.sol";
import {IExposureLedger} from "../src/interfaces/IExposureLedger.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract PayableRouter is PoolModifyLiquidityTest {
    constructor(IPoolManager manager) PoolModifyLiquidityTest(manager) {}
    receive() external payable {}
}

/// @title ExposureLedgerQueryTest
/// @notice Unit tests for Phase 5 — Query Interface (Task 5.1).
///
/// Coverage
/// ─────────
///   § getLPTotalExternality
///       • Zero initially
///       • Accumulates after single resolution
///       • Accumulates across multiple episodes
///       • Independent per LP
///
///   § getLPEpisodeAttribution
///       • Zero for unresolved episode
///       • Zero for episode LP was not exposed in
///       • Correct value after resolution
///       • Independent per (LP, episode) pair
///
///   § getLPSegments
///       • Empty array initially
///       • One segment after first add
///       • Two segments after second add (same or different range)
///       • History preserved after segment closed (lastEpisodeId updated)
///       • Fields (lp, tickLower, tickUpper, liquidity, firstEpisodeId) correct
///
///   § getEpisode
///       • Correct block data (blockNumber, tick, sqrtPriceX96, activeLiquidity)
///       • Correct amounts (amount0, amount1, tradeDirection)
///       • Unresolved state (externality=0, resolved=false)
///       • Resolved state after resolveEpisode
///
///   § getLPActiveSegment
///       • Reverts with NoActiveSegment when LP has no segment
///       • Reverts with NoActiveSegment after segment is closed
///       • Returns correct segment when one is open
///       • Returns the open segment among multiple (closed + open)
///
///   § nextEpisodeId
///       • Starts at zero
///       • Increments after each swap
///
///   § getEpisodeExposedLPs / episodeExposedLPCount
///       • Correct count and addresses
///
///   § activeLPCount / getActiveLPList
///       • Count and list correctness
contract ExposureLedgerQueryTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    ExposureLedgerHook public hook;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;

    address public proxy = makeAddr("reactive_proxy");

    PayableRouter public seedRouter;
    PayableRouter public lpA;
    PayableRouter public lpB;

    int24 tickLower;
    int24 tickUpper;
    int24 tightLower =  -60;
    int24 tightUpper =   60;

    uint128 constant SEED_LIQ = 100e18;
    uint128 constant LP_A_LIQ = 50e18;
    uint128 constant LP_B_LIQ = 25e18;
    uint256 constant EXTERNALITY = 1 ether;

    uint160 constant HOOK_FLAGS =
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
        Hooks.AFTER_SWAP_FLAG           |
        Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;

    // -------------------------------------------------------------------------
    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        address hookAddr = address(uint160(HOOK_FLAGS) ^ (0x4444 << 144));
        deployCodeTo("ExposureLedgerHook.sol:ExposureLedgerHook", abi.encode(poolManager, address(this)), hookAddr);
        hook = ExposureLedgerHook(hookAddr);
        hook.setReactiveCallbackProxy(proxy);

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        seedRouter = new PayableRouter(poolManager);
        _approve(seedRouter);
        _addLiq(seedRouter, SEED_LIQ, tickLower, tickUpper);

        lpA = new PayableRouter(poolManager);
        _approve(lpA);

        lpB = new PayableRouter(poolManager);
        _approve(lpB);
    }

    // =========================================================================
    // § getLPTotalExternality
    // =========================================================================

    /// @notice Total externality starts at zero for any LP address.
    function test_queryLP_totalExternality_startsAtZero() public {
        assertEq(hook.getLPTotalExternality(address(lpA)), 0);
        assertEq(hook.getLPTotalExternality(address(lpB)), 0);
        assertEq(hook.getLPTotalExternality(makeAddr("nobody")), 0);
    }

    /// @notice Total externality reflects attribution from one resolved episode.
    function test_queryLP_totalExternality_afterOneEpisode() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _swap(1 ether);
        _resolve(0, EXTERNALITY);

        assertGt(hook.getLPTotalExternality(address(lpA)), 0);
    }

    /// @notice Total externality accumulates correctly across multiple episodes.
    function test_queryLP_totalExternality_accumulatesAcrossEpisodes() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);

        _swap(1 ether);        // episode 0
        _resolve(0, EXTERNALITY);

        uint256 after0 = hook.getLPTotalExternality(address(lpA));
        assertGt(after0, 0);

        _swap(1 ether);        // episode 1
        _resolve(1, EXTERNALITY);

        uint256 after1 = hook.getLPTotalExternality(address(lpA));
        assertGt(after1, after0, "must accumulate after second episode");
    }

    /// @notice Total externality is independent per LP address.
    function test_queryLP_totalExternality_independentPerLP() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _addLiq(lpB, LP_B_LIQ, tickLower, tickUpper);
        _swap(1 ether);
        _resolve(0, EXTERNALITY);

        uint256 attrA = hook.getLPTotalExternality(address(lpA));
        uint256 attrB = hook.getLPTotalExternality(address(lpB));

        // Both non-zero and different (different liquidity)
        assertGt(attrA, 0);
        assertGt(attrB, 0);
        assertNotEq(attrA, attrB);
    }

    // =========================================================================
    // § getLPEpisodeAttribution
    // =========================================================================

    /// @notice Per-episode attribution is zero before the episode is resolved.
    function test_queryLP_episodeAttribution_zeroBeforeResolve() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _swap(1 ether);
        // Do NOT resolve

        assertEq(hook.getLPEpisodeAttribution(address(lpA), 0), 0);
    }

    /// @notice Per-episode attribution is zero for an episode the LP wasn't exposed in.
    function test_queryLP_episodeAttribution_zeroIfNotExposed() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _swap(1 ether);
        _resolve(0, EXTERNALITY);

        // lpB never added liquidity — episode 0 attribution must be 0
        assertEq(hook.getLPEpisodeAttribution(address(lpB), 0), 0);
    }

    /// @notice Per-episode attribution equals total when there is only one episode.
    function test_queryLP_episodeAttribution_matchesTotalForSingleEpisode() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _swap(1 ether);
        _resolve(0, EXTERNALITY);

        uint256 perEp    = hook.getLPEpisodeAttribution(address(lpA), 0);
        uint256 perTotal = hook.getLPTotalExternality(address(lpA));
        assertEq(perEp, perTotal);
    }

    /// @notice Per-episode attributions are independent across episodes.
    function test_queryLP_episodeAttribution_independentPerEpisode() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);

        _swap(1 ether);
        _resolve(0, EXTERNALITY);

        _swap(0.5 ether);
        _resolve(1, EXTERNALITY / 2);

        uint256 ep0 = hook.getLPEpisodeAttribution(address(lpA), 0);
        uint256 ep1 = hook.getLPEpisodeAttribution(address(lpA), 1);

        assertGt(ep0, 0);
        assertGt(ep1, 0);
        // ep0 should be larger (full externality vs half)
        assertGt(ep0, ep1);

        uint256 total = hook.getLPTotalExternality(address(lpA));
        assertEq(total, ep0 + ep1);
    }

    // =========================================================================
    // § getLPSegments
    // =========================================================================

    /// @notice getLPSegments returns empty array before any liquidity added.
    function test_queryLP_segments_emptyInitially() public {
        IExposureLedger.LPExposureSegment[] memory segs = hook.getLPSegments(address(lpA));
        assertEq(segs.length, 0);
    }

    /// @notice One segment after a single add.
    function test_queryLP_segments_oneAfterAdd() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        IExposureLedger.LPExposureSegment[] memory segs = hook.getLPSegments(address(lpA));
        assertEq(segs.length, 1);
    }

    /// @notice Segment fields are set correctly.
    function test_queryLP_segments_fieldsCorrect() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        IExposureLedger.LPExposureSegment[] memory segs = hook.getLPSegments(address(lpA));

        assertEq(segs[0].lp,        address(lpA));
        assertEq(segs[0].tickLower, tickLower);
        assertEq(segs[0].tickUpper, tickUpper);
        assertEq(segs[0].liquidity, LP_A_LIQ);
        // Active sentinel
        assertEq(segs[0].lastEpisodeId, type(uint64).max);
    }

    /// @notice firstEpisodeId reflects nextEpisodeId at time of add.
    function test_queryLP_segments_firstEpisodeId() public {
        // Create one episode before lpA adds
        _addLiq(lpB, LP_B_LIQ, tickLower, tickUpper);
        _swap(1 ether); // nextEpisodeId becomes 1

        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        IExposureLedger.LPExposureSegment[] memory segs = hook.getLPSegments(address(lpA));
        assertEq(segs[0].firstEpisodeId, 1, "firstEpisodeId must be nextEpisodeId at add time");
    }

    /// @notice Two segments after two separate add calls.
    function test_queryLP_segments_twoAfterTwoAdds() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _addLiq(lpA, LP_A_LIQ, tightLower, tightUpper);

        IExposureLedger.LPExposureSegment[] memory segs = hook.getLPSegments(address(lpA));
        assertEq(segs.length, 2);
        assertEq(segs[0].tickLower, tickLower);
        assertEq(segs[1].tickLower, tightLower);
    }

    /// @notice After removing liquidity, segment history is preserved with lastEpisodeId set.
    function test_queryLP_segments_historyPreservedAfterClose() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _swap(1 ether); // episode 0
        _removeLiq(lpA, LP_A_LIQ, tickLower, tickUpper);

        IExposureLedger.LPExposureSegment[] memory segs = hook.getLPSegments(address(lpA));
        assertEq(segs.length, 1, "segment history must be preserved");
        assertNotEq(segs[0].lastEpisodeId, type(uint64).max, "segment must be closed");
        // Closed at episode 0 (nextEpisodeId - 1 = 0)
        assertEq(segs[0].lastEpisodeId, 0);
    }

    // =========================================================================
    // § getEpisode
    // =========================================================================

    /// @notice getEpisode returns correct block data.
    function test_queryLP_getEpisode_blockData() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);

        uint256 swapBlock = block.number;
        _swap(1 ether);

        IExposureLedger.SwapEpisode memory ep = hook.getEpisode(0);
        assertEq(ep.episodeId,    0);
        assertEq(ep.blockNumber,  uint64(swapBlock));
        assertGt(ep.sqrtPriceX96, 0);
        assertGt(ep.activeLiquidity, 0);
    }

    /// @notice Episode is unresolved immediately after creation.
    function test_queryLP_getEpisode_unresolvedState() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _swap(1 ether);

        IExposureLedger.SwapEpisode memory ep = hook.getEpisode(0);
        assertFalse(ep.resolved);
        assertEq(ep.externality, 0);
    }

    /// @notice Episode shows resolved state and externality after resolveEpisode.
    function test_queryLP_getEpisode_resolvedState() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _swap(1 ether);
        _resolve(0, EXTERNALITY);

        IExposureLedger.SwapEpisode memory ep = hook.getEpisode(0);
        assertTrue(ep.resolved);
        assertEq(ep.externality, EXTERNALITY);
    }

    /// @notice Episode trade direction: zeroForOne sets direction = 0.
    ///
    /// @dev In the afterSwap callback, delta.amount0() < 0 when zeroForOne=true
    ///      (token0 flows out of the hook's balance perspective).
    ///      hook stores: direction = delta.amount0() < 0 ? 0 : 1
    ///      So: zeroForOne=true -> amount0 < 0 -> direction = 0 (token0 sold)
    ///          zeroForOne=false -> amount0 > 0 -> direction = 1 (token1 sold)
    function test_queryLP_getEpisode_tradeDirection() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _swap(1 ether); // zeroForOne = true -> direction = 0

        IExposureLedger.SwapEpisode memory ep = hook.getEpisode(0);
        assertEq(ep.tradeDirection, 0, "zeroForOne swap must give direction = 0");
    }

    /// @notice createdTimestamp is set correctly.
    function test_queryLP_getEpisode_timestamp() public {
        uint256 t = block.timestamp;
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _swap(1 ether);

        assertEq(hook.getEpisode(0).createdTimestamp, t);
    }

    // =========================================================================
    // § getLPActiveSegment
    // =========================================================================

    /// @notice Reverts with NoActiveSegment when LP has never added liquidity.
    function test_queryLP_activeSegment_revertsIfNone() public {
        vm.expectRevert(IExposureLedger.NoActiveSegment.selector);
        hook.getLPActiveSegment(address(lpA));
    }

    /// @notice Reverts after LP removes their only position.
    function test_queryLP_activeSegment_revertsAfterClose() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _swap(1 ether);
        _removeLiq(lpA, LP_A_LIQ, tickLower, tickUpper);

        vm.expectRevert(IExposureLedger.NoActiveSegment.selector);
        hook.getLPActiveSegment(address(lpA));
    }

    /// @notice Returns correct segment when one is open.
    function test_queryLP_activeSegment_returnsOpenSegment() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);

        IExposureLedger.LPExposureSegment memory active = hook.getLPActiveSegment(address(lpA));
        assertEq(active.lp,        address(lpA));
        assertEq(active.tickLower, tickLower);
        assertEq(active.tickUpper, tickUpper);
        assertEq(active.liquidity, LP_A_LIQ);
        assertEq(active.lastEpisodeId, type(uint64).max); // active sentinel
    }

    /// @notice Returns the open segment when there are both closed and open segments.
    function test_queryLP_activeSegment_returnsOpenAmongMultiple() public {
        // Add and then close first segment
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _swap(1 ether);
        _removeLiq(lpA, LP_A_LIQ, tickLower, tickUpper); // closed

        // Add a new open segment at different range
        _addLiq(lpA, LP_A_LIQ, tightLower, tightUpper);

        IExposureLedger.LPExposureSegment memory active = hook.getLPActiveSegment(address(lpA));
        // Must return the second (open) segment
        assertEq(active.tickLower, tightLower);
        assertEq(active.tickUpper, tightUpper);
        assertEq(active.lastEpisodeId, type(uint64).max);
    }

    // =========================================================================
    // § nextEpisodeId
    // =========================================================================

    /// @notice nextEpisodeId starts at 0 before any swaps.
    function test_queryLP_nextEpisodeId_startsAtZero() public {
        assertEq(hook.nextEpisodeId(), 0);
    }

    /// @notice nextEpisodeId increments by 1 for each swap.
    function test_queryLP_nextEpisodeId_incrementsPerSwap() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);

        _swap(1 ether);
        assertEq(hook.nextEpisodeId(), 1);

        _swap(1 ether);
        assertEq(hook.nextEpisodeId(), 2);

        _swap(1 ether);
        assertEq(hook.nextEpisodeId(), 3);
    }

    // =========================================================================
    // § getEpisodeExposedLPs / episodeExposedLPCount
    // =========================================================================

    /// @notice getEpisodeExposedLPs returns the correct addresses.
    function test_queryLP_episodeExposedLPs() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _addLiq(lpB, LP_B_LIQ, tickLower, tickUpper);
        _swap(1 ether);

        address[] memory exposed = hook.getEpisodeExposedLPs(0);
        bool foundA; bool foundB; bool foundSeed;
        for (uint256 i; i < exposed.length; i++) {
            if (exposed[i] == address(lpA))        foundA    = true;
            if (exposed[i] == address(lpB))        foundB    = true;
            if (exposed[i] == address(seedRouter)) foundSeed = true;
        }
        assertTrue(foundA);
        assertTrue(foundB);
        assertTrue(foundSeed);
    }

    /// @notice episodeExposedLPCount matches exposed list length.
    function test_queryLP_episodeExposedLPCount() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _swap(1 ether);

        uint256 count = hook.episodeExposedLPCount(0);
        address[] memory list = hook.getEpisodeExposedLPs(0);
        assertEq(count, list.length);
    }

    // =========================================================================
    // § activeLPCount / getActiveLPList
    // =========================================================================

    /// @notice activeLPCount reflects number of distinct LP addresses.
    function test_queryLP_activeLPCount() public {
        uint256 before = hook.activeLPCount(); // seedRouter already registered in setUp

        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        assertEq(hook.activeLPCount(), before + 1);

        _addLiq(lpB, LP_B_LIQ, tickLower, tickUpper);
        assertEq(hook.activeLPCount(), before + 2);

        // Duplicate add from lpA must not change count
        _addLiq(lpA, LP_A_LIQ, tightLower, tightUpper);
        assertEq(hook.activeLPCount(), before + 2);
    }

    /// @notice getActiveLPList contains all registered addresses.
    function test_queryLP_getActiveLPList() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _addLiq(lpB, LP_B_LIQ, tickLower, tickUpper);

        address[] memory list = hook.getActiveLPList();
        bool foundA; bool foundB;
        for (uint256 i; i < list.length; i++) {
            if (list[i] == address(lpA)) foundA = true;
            if (list[i] == address(lpB)) foundB = true;
        }
        assertTrue(foundA, "lpA must be in active list");
        assertTrue(foundB, "lpB must be in active list");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _resolve(uint256 episodeId, uint256 externality) internal {
        vm.prank(proxy);
        hook.resolveEpisode(episodeId, externality);
    }

    function _swap(uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function _addLiq(PayableRouter router, uint128 liquidity, int24 lower, int24 upper) internal {
        router.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            Constants.ZERO_BYTES
        );
    }

    function _removeLiq(PayableRouter router, uint128 liquidity, int24 lower, int24 upper) internal {
        router.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: -int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            Constants.ZERO_BYTES
        );
    }

    function _approve(PayableRouter router) internal {
        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
    }

    receive() external payable {}
}
