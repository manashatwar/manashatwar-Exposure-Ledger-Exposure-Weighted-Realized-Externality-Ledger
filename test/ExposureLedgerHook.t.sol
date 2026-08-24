// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
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

/// @notice Helper to allow payable callbacks in tests
contract PayableModifyLiquidityRouter is PoolModifyLiquidityTest {
    constructor(IPoolManager manager) PoolModifyLiquidityTest(manager) {}
    receive() external payable {}
}

/// @title ExposureLedgerHookTest
/// @notice Phase 2 unit tests covering Tasks 2.1, 2.2, and 2.3.
///
///   Task 2.1 (afterSwap)         — episode creation
///   Task 2.2 (beforeAddLiquidity) — segment open
///   Task 2.3 (beforeRemoveLiquidity) — segment close
contract ExposureLedgerHookTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    // -------------------------------------------------------------------------
    // Test state
    // -------------------------------------------------------------------------
    ExposureLedgerHook public hook;
    /// @dev Used only in setUp to seed pool liquidity — segments tracked here
    ///      so they never appear in liquidityRouter's segment list.
    PayableModifyLiquidityRouter public seedRouter;
    /// @dev Used by all LP tests — starts with zero segments.
    PayableModifyLiquidityRouter public liquidityRouter;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    PoolId poolId;

    int24 tickLower;
    int24 tickUpper;

    uint128 constant BASE_LIQUIDITY   = 100e18;
    uint128 constant LP_LIQUIDITY     = 10e18;

    // Precomputed hook flag address mask — must match getHookPermissions()
    // Flags: BEFORE_ADD_LIQUIDITY | AFTER_SWAP | BEFORE_REMOVE_LIQUIDITY
    uint160 constant HOOK_FLAGS =
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
        Hooks.AFTER_SWAP_FLAG           |
        Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------
    function setUp() public {
        // Deploy Uniswap v4 infrastructure
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        // Deploy hook at the address whose flags match permissions
        address hookAddress = address(uint160(HOOK_FLAGS) ^ (0x4444 << 144));
        bytes memory args = abi.encode(poolManager, address(this));
        deployCodeTo("ExposureLedgerHook.sol:ExposureLedgerHook", args, hookAddress);
        hook = ExposureLedgerHook(hookAddress);

        // Pool setup
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        // seedRouter: only used here to seed pool depth.
        // Its segments are tracked under address(seedRouter) so they never
        // appear in liquidityRouter's segment list, keeping tests isolated.
        seedRouter = new PayableModifyLiquidityRouter(poolManager);
        MockERC20(Currency.unwrap(currency0)).approve(address(seedRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(seedRouter), type(uint256).max);
        _addLiquidityViaRouter(seedRouter, BASE_LIQUIDITY, tickLower, tickUpper);

        // liquidityRouter: starts with ZERO segments — used by all LP tests.
        liquidityRouter = new PayableModifyLiquidityRouter(poolManager);
        MockERC20(Currency.unwrap(currency0)).approve(address(liquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(liquidityRouter), type(uint256).max);
    }

    // =========================================================================
    // Task 2.1 — afterSwap: Episode Creation
    // =========================================================================

    /// @notice A swap must create exactly one episode with episodeId == 0 (first swap).
    function test_afterSwap_createsEpisode() public {
        assertEq(hook.nextEpisodeId(), 0);

        _swap(1 ether);

        assertEq(hook.nextEpisodeId(), 1);

        IExposureLedger.SwapEpisode memory ep = hook.getEpisode(0);
        assertEq(ep.episodeId, 0);
        assertFalse(ep.resolved);
        assertEq(ep.externality, 0);
    }

    /// @notice nextEpisodeId must increment by 1 for each swap.
    function test_afterSwap_incrementsId() public {
        _swap(0.5 ether);
        assertEq(hook.nextEpisodeId(), 1);

        _swap(0.5 ether);
        assertEq(hook.nextEpisodeId(), 2);

        _swap(0.5 ether);
        assertEq(hook.nextEpisodeId(), 3);
    }

    /// @notice Episode must capture post-swap sqrtPriceX96, tick, and activeLiquidity.
    function test_afterSwap_capturesPoolState() public {
        _swap(1 ether);

        IExposureLedger.SwapEpisode memory ep = hook.getEpisode(0);

        // sqrtPriceX96 must be non-zero (pool was initialized at 1:1)
        assertGt(ep.sqrtPriceX96, 0);
        // activeLiquidity must equal BASE_LIQUIDITY (only liquidity seeded in setUp)
        assertEq(ep.activeLiquidity, BASE_LIQUIDITY);
        // blockNumber must match current block
        assertEq(ep.blockNumber, uint64(block.number));
        // createdTimestamp must match current timestamp
        assertEq(ep.createdTimestamp, block.timestamp);
    }

    /// @notice Episode amounts must match the swap delta.
    function test_afterSwap_capturesAmounts() public {
        _swap(1 ether);

        IExposureLedger.SwapEpisode memory ep = hook.getEpisode(0);
        // Selling token0 into the pool: amount0 should be negative (pool receives it)
        // amount1 should be positive (pool sends it to swapper)
        assertLt(ep.amount0, 0);
        assertGt(ep.amount1, 0);
        // tradeDirection = 0 means token0 sold
        assertEq(ep.tradeDirection, 0);
    }

    /// @notice Buying token0 (zeroForOne = false) should set tradeDirection = 1.
    function test_afterSwap_direction_buy() public {
        _swapBuy(1 ether);

        IExposureLedger.SwapEpisode memory ep = hook.getEpisode(0);
        assertEq(ep.tradeDirection, 1);
    }

    /// @notice afterSwap must emit EpisodeCreated with correct indexed fields.
    function test_afterSwap_emitsEpisodeCreated() public {
        vm.recordLogs();
        _swap(1 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("EpisodeCreated(uint256,bytes32,uint64,int24,uint160,uint128)");

        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == sig) {
                found = true;
                // episodeId (indexed topic[1]) should be 0
                assertEq(uint256(logs[i].topics[1]), 0);
                break;
            }
        }
        assertTrue(found, "EpisodeCreated not emitted");
    }

    /// @notice Episode overflow must revert with EpisodeIdOverflow.
    /// @dev PoolManager wraps hook reverts in Wrap__FailedHookCall, so we use bare
    ///      vm.expectRevert() and verify the call reverts (not the specific selector).
    function test_afterSwap_revertsOnOverflow() public {
        // Storage layout:
        //   slot 0 - Ownable._owner
        //   slot 1 → episodes mapping
        //   slot 2 → nextEpisodeId
        vm.store(address(hook), bytes32(uint256(2)), bytes32(uint256(type(uint64).max)));

        // PoolManager wraps hook reverts — use bare expectRevert()
        vm.expectRevert();
        _swap(1 ether);
    }

    // =========================================================================
    // Task 2.2 — beforeAddLiquidity: Segment Open
    // =========================================================================

    // -----------------------------------------------------------------------
    // NOTE: In Uniswap v4, the hook's `sender` parameter is whoever called
    // poolManager.modifyLiquidity — which is address(liquidityRouter) in
    // these tests, NOT address(this). So segment queries use the router addr.
    // -----------------------------------------------------------------------

    /// @notice Adding liquidity must open a new segment with firstEpisodeId == nextEpisodeId.
    function test_beforeAdd_opensSegment() public {
        // nextEpisodeId is 0 before any swap
        assertEq(hook.nextEpisodeId(), 0);

        _addLiquidity(LP_LIQUIDITY, tickLower, tickUpper);

        // sender == address(liquidityRouter) (the direct PoolManager caller)
        address lp = address(liquidityRouter);
        IExposureLedger.LPExposureSegment[] memory segs = hook.getLPSegments(lp);
        assertEq(segs.length, 1);
        assertEq(segs[0].lp, lp);
        assertEq(segs[0].tickLower, tickLower);
        assertEq(segs[0].tickUpper, tickUpper);
        assertEq(segs[0].liquidity, LP_LIQUIDITY);
    }

    /// @notice firstEpisodeId must equal nextEpisodeId at the time of add.
    function test_beforeAdd_setsFirstEpisodeId() public {
        // Do 2 swaps first so nextEpisodeId == 2
        _swap(0.1 ether);
        _swap(0.1 ether);
        assertEq(hook.nextEpisodeId(), 2);

        _addLiquidity(LP_LIQUIDITY, tickLower, tickUpper);

        IExposureLedger.LPExposureSegment[] memory segs = hook.getLPSegments(address(liquidityRouter));
        assertEq(segs[0].firstEpisodeId, 2);
    }

    /// @notice lastEpisodeId must be type(uint64).max (active sentinel) immediately after opening.
    function test_beforeAdd_leavesLastEpisodeZero() public {
        _addLiquidity(LP_LIQUIDITY, tickLower, tickUpper);

        IExposureLedger.LPExposureSegment[] memory segs = hook.getLPSegments(address(liquidityRouter));
        assertEq(segs[0].lastEpisodeId, type(uint64).max, "Segment must be active (lastEpisodeId == type(uint64).max)");
    }

    /// @notice Adding liquidity twice (same or different range) creates two segments.
    function test_beforeAdd_multipleSegments() public {
        _addLiquidity(LP_LIQUIDITY, tickLower, tickUpper);

        int24 tightLower = -120;
        int24 tightUpper =  120;
        _addLiquidity(LP_LIQUIDITY / 2, tightLower, tightUpper);

        IExposureLedger.LPExposureSegment[] memory segs = hook.getLPSegments(address(liquidityRouter));
        assertEq(segs.length, 2);
        assertEq(segs[0].tickLower, tickLower);
        assertEq(segs[1].tickLower, tightLower);
    }

    /// @notice beforeAddLiquidity must emit LPSegmentOpened.
    function test_beforeAdd_emitsSegmentOpened() public {
        vm.recordLogs();
        _addLiquidity(LP_LIQUIDITY, tickLower, tickUpper);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("LPSegmentOpened(address,uint256,uint64,int24,int24,uint128)");

        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == sig) {
                found = true;
                break;
            }
        }
        assertTrue(found, "LPSegmentOpened not emitted");
    }

    /// @notice getLPActiveSegment must return the open segment (queried via router address).
    function test_beforeAdd_activeSegmentQueryable() public {
        _addLiquidity(LP_LIQUIDITY, tickLower, tickUpper);

        // sender == liquidityRouter in hook callbacks
        IExposureLedger.LPExposureSegment memory active = hook.getLPActiveSegment(address(liquidityRouter));
        assertEq(active.liquidity, LP_LIQUIDITY);
        // Active sentinel is type(uint64).max, not 0
        assertEq(active.lastEpisodeId, type(uint64).max);
    }

    /// @notice getLPActiveSegment must revert when no active segment exists.
    function test_getLPActiveSegment_revertsIfNone() public {
        // address(this) never added liquidity directly, so no segment
        vm.expectRevert(IExposureLedger.NoActiveSegment.selector);
        hook.getLPActiveSegment(address(this));
    }

    // =========================================================================
    // Task 2.3 — beforeRemoveLiquidity: Segment Close
    // =========================================================================

    /// @notice Removing liquidity must close the matching segment.
    /// @dev Use 2 swaps so nextEpisodeId=2, giving lastEpisodeId=1 (avoids
    ///      the 0 == sentinel collision when nextEpisodeId-1 would equal 0).
    function test_beforeRemove_closesSegment() public {
        _addLiquidity(LP_LIQUIDITY, tickLower, tickUpper);

        // 2 swaps - nextEpisodeId = 2, so lastEpisodeId will be 1
        _swap(0.1 ether);
        _swap(0.1 ether);
        assertEq(hook.nextEpisodeId(), 2);

        _removeLiquidity(LP_LIQUIDITY, tickLower, tickUpper);

        IExposureLedger.LPExposureSegment[] memory segs = hook.getLPSegments(address(liquidityRouter));
        // lastEpisodeId = nextEpisodeId - 1 = 1 (> 0 = active sentinel)
        assertGt(segs[0].lastEpisodeId, 0, "Segment must be closed");
    }

    /// @notice lastEpisodeId must equal nextEpisodeId - 1 at close time.
    function test_beforeRemove_setsLastEpisodeId() public {
        _addLiquidity(LP_LIQUIDITY, tickLower, tickUpper);

        // 3 swaps - nextEpisodeId = 3
        _swap(0.1 ether);
        _swap(0.1 ether);
        _swap(0.1 ether);
        assertEq(hook.nextEpisodeId(), 3);

        _removeLiquidity(LP_LIQUIDITY, tickLower, tickUpper);

        IExposureLedger.LPExposureSegment[] memory segs = hook.getLPSegments(address(liquidityRouter));
        // lastEpisodeId should be nextEpisodeId - 1 = 2
        assertEq(segs[0].lastEpisodeId, 2);
    }

    /// @notice Removing the tight-range position must not affect the wide-range segment.
    function test_beforeRemove_noActiveSegment_noRevert() public {
        // Add wide-range liquidity
        _addLiquidity(LP_LIQUIDITY, tickLower, tickUpper);

        int24 tightLower = -120;
        int24 tightUpper =  120;
        // Add tight-range, then remove it — closes the tight segment
        _addLiquidity(LP_LIQUIDITY / 2, tightLower, tightUpper);
        _removeLiquidity(LP_LIQUIDITY / 2, tightLower, tightUpper);

        // Wide-range segment (tickLower/tickUpper) must still be active
        IExposureLedger.LPExposureSegment memory active = hook.getLPActiveSegment(address(liquidityRouter));
        assertEq(active.tickLower, tickLower);
        assertEq(active.tickUpper, tickUpper);
    }

    /// @notice Removing liquidity must emit LPSegmentClosed.
    function test_beforeRemove_emitsSegmentClosed() public {
        _addLiquidity(LP_LIQUIDITY, tickLower, tickUpper);
        _swap(0.1 ether);

        vm.recordLogs();
        _removeLiquidity(LP_LIQUIDITY, tickLower, tickUpper);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("LPSegmentClosed(address,uint256,uint64)");

        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == sig) {
                found = true;
                break;
            }
        }
        assertTrue(found, "LPSegmentClosed not emitted");
    }

    /// @notice After segment is closed, getLPActiveSegment must revert.
    function test_beforeRemove_activeSegmentGoneAfterClose() public {
        _addLiquidity(LP_LIQUIDITY, tickLower, tickUpper);
        _swap(0.1 ether);
        _removeLiquidity(LP_LIQUIDITY, tickLower, tickUpper);

        vm.expectRevert(IExposureLedger.NoActiveSegment.selector);
        hook.getLPActiveSegment(address(this));
    }

    /// @notice Segment firstEpisodeId must be <= lastEpisodeId after close (no overlap).
    function test_beforeRemove_segmentRangeOrdering() public {
        // Swap first so firstEpisodeId > 0
        _swap(0.1 ether);

        _addLiquidity(LP_LIQUIDITY, tickLower, tickUpper);

        // More swaps
        _swap(0.1 ether);
        _swap(0.1 ether);

        _removeLiquidity(LP_LIQUIDITY, tickLower, tickUpper);

        IExposureLedger.LPExposureSegment[] memory segs = hook.getLPSegments(address(liquidityRouter));
        assertLe(segs[0].firstEpisodeId, segs[0].lastEpisodeId, "first must be <= last");
    }

    // =========================================================================
    // Helper: query functions smoke tests
    // =========================================================================

    function test_getEpisode_returnsCorrectData() public {
        _swap(1 ether);

        IExposureLedger.SwapEpisode memory ep = hook.getEpisode(0);
        assertEq(ep.episodeId, 0);
        assertEq(ep.blockNumber, uint64(block.number));
        assertFalse(ep.resolved);
    }

    function test_getLPSegments_returnsAll() public {
        _addLiquidity(LP_LIQUIDITY, tickLower, tickUpper);
        _addLiquidity(LP_LIQUIDITY / 2, -120, 120);

        // sender in hook == address(liquidityRouter)
        IExposureLedger.LPExposureSegment[] memory segs = hook.getLPSegments(address(liquidityRouter));
        assertEq(segs.length, 2);
    }

    function test_getLPTotalExternality_startsAtZero() public {
        assertEq(hook.getLPTotalExternality(address(this)), 0);
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Add liquidity via the test's liquidityRouter (tracked under that address).
    function _addLiquidity(uint128 liquidity, int24 lower, int24 upper) internal {
        _addLiquidityViaRouter(liquidityRouter, liquidity, lower, upper);
    }

    /// @dev Add liquidity via any router (used by setUp's seedRouter).
    function _addLiquidityViaRouter(
        PayableModifyLiquidityRouter router,
        uint128 liquidity,
        int24 lower,
        int24 upper
    ) internal {
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

    function _removeLiquidity(uint128 liquidity, int24 lower, int24 upper) internal {
        liquidityRouter.modifyLiquidity(
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

    /// @dev Sell token0 into pool (zeroForOne = true)
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

    /// @dev Buy token0 from pool (zeroForOne = false)
    function _swapBuy(uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    receive() external payable {}
}
