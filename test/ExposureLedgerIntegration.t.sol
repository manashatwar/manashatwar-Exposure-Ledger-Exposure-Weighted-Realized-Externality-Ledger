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
import {MockReactive} from "./mocks/MockReactive.sol";

contract PayableRouter is PoolModifyLiquidityTest {
    constructor(IPoolManager manager) PoolModifyLiquidityTest(manager) {}
    receive() external payable {}
}

/// @title ExposureLedgerIntegrationTest
/// @notice End-to-end integration tests for the complete ILFlow system.
///         Uses MockReactive to simulate the Reactive Network RSC.
///
/// Flow Under Test
/// ───────────────
///   1. LP adds liquidity (segment opened)
///   2. Swap executes (episode created, exposedLPs populated)
///   3. MockReactive waits OBSERVATION_HORIZON blocks
///   4. MockReactive resolves episode (calls hook.resolveEpisode)
///   5. Attribution executes - LP queries externality
///
/// Edge Cases
/// ──────────
///   • LP exits before resolution (still gets attribution via segment history)
///   • Multiple LPs with different liquidity (fair proportional distribution)
///   • Zero externality RSPE (attribution skipped cleanly)
///   • Manual fallback after 7-day timeout (Reactive never called)
///   • Two swaps - two episodes - independent resolutions
///   • LP adds AFTER swap (not exposed to that episode)
contract ExposureLedgerIntegrationTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    ExposureLedgerHook public hook;
    MockReactive       public reactive;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;

    PayableRouter public seedRouter;
    PayableRouter public lpA;
    PayableRouter public lpB;

    int24 tickLower;
    int24 tickUpper;

    uint128 constant SEED_LIQ  = 200e18;
    uint128 constant LP_A_LIQ  = 100e18;
    uint128 constant LP_B_LIQ  = 50e18;
    uint256 constant PRICE_D   = 1e18;  // reference price at swap block
    uint256 constant PRICE_A   = 11e17; // +10% markout (RSPE = ~0)
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

        reactive = new MockReactive();
        hook.setReactiveCallbackProxy(address(reactive));

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
    // Happy path: single LP, single episode
    // =========================================================================

    /// @notice Full happy-path flow: add - swap - wait - resolve - query.
    function test_integration_happyPath_singleLP() public {
        // 1. LP adds liquidity
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);

        // 2. Swap - episode 0 created
        _swap(1 ether);
        assertEq(hook.nextEpisodeId(), 1);

        IExposureLedger.SwapEpisode memory ep = hook.getEpisode(0);
        assertFalse(ep.resolved);

        // 3. Register episode with MockReactive
        reactive.onEpisodeCreated(0, ep.sqrtPriceX96, 1 ether);

        // 4. Roll forward past observation horizon
        vm.roll(block.number + reactive.OBSERVATION_HORIZON() + 1);
        assertTrue(reactive.horizonReached(0));

        // 5. Reactive resolves with direct externality
        reactive.resolveDirectly(address(hook), 0, EXTERNALITY);

        // 6. Verify resolution
        IExposureLedger.SwapEpisode memory resolved = hook.getEpisode(0);
        assertTrue(resolved.resolved);
        assertEq(resolved.externality, EXTERNALITY);

        // 7. LP queries attribution
        uint256 attrA = hook.getLPTotalExternality(address(lpA));
        assertGt(attrA, 0, "LP must have positive externality attribution");
    }

    // =========================================================================
    // Edge case: LP exits before resolution
    // =========================================================================

    /// @notice LP that removes liquidity BEFORE resolution still gets attributed
    ///         because the segment history is preserved and _getActiveSegmentAt
    ///         uses firstEpisodeId/lastEpisodeId range checks.
    function test_integration_lpExitsBeforeResolution_stillAttributed() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);

        // Swap - episode 0 (lpA in range)
        _swap(1 ether);
        IExposureLedger.SwapEpisode memory ep = hook.getEpisode(0);
        reactive.onEpisodeCreated(0, ep.sqrtPriceX96, 1 ether);

        // LP exits BEFORE resolution
        _removeLiq(lpA, LP_A_LIQ, tickLower, tickUpper);

        // Resolution happens after exit
        vm.roll(block.number + reactive.OBSERVATION_HORIZON() + 1);
        reactive.resolveDirectly(address(hook), 0, EXTERNALITY);

        // lpA was exposed at episode 0 — must still receive attribution
        uint256 attrA = hook.getLPTotalExternality(address(lpA));
        assertGt(attrA, 0, "LP that exited before resolution must still be attributed");
    }

    // =========================================================================
    // Edge case: multiple LPs, fair distribution
    // =========================================================================

    /// @notice Two LPs receive proportional attribution based on their liquidity.
    function test_integration_multipleLPs_fairDistribution() public {
        // lpA has 2x the liquidity of lpB
        _addLiq(lpA, LP_A_LIQ * 2, tickLower, tickUpper); // 200e18
        _addLiq(lpB, LP_A_LIQ,     tickLower, tickUpper); // 100e18

        _swap(1 ether);
        reactive.resolveDirectly(address(hook), 0, EXTERNALITY);

        uint256 attrA = hook.getLPTotalExternality(address(lpA));
        uint256 attrB = hook.getLPTotalExternality(address(lpB));

        // Both non-zero
        assertGt(attrA, 0);
        assertGt(attrB, 0);

        // lpA has 2x liquidity - gets roughly 2x attribution
        assertGt(attrA, attrB, "higher liquidity LP must receive more attribution");

        // Sum must not exceed externality
        uint256 total = attrA + attrB + hook.getLPTotalExternality(address(seedRouter));
        assertLe(total, EXTERNALITY, "total attribution must not exceed externality");
    }

    // =========================================================================
    // Edge case: zero externality (RSPE = 0)
    // =========================================================================

    /// @notice When RSPE is 0 (no stale markout), resolve succeeds but
    ///         attribution is skipped and no ExternalityAttributed events fire.
    function test_integration_zeroExternality_skipsAttribution() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _swap(1 ether);

        vm.recordLogs();
        reactive.resolveDirectly(address(hook), 0, 0); // RSPE = 0
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Must be resolved
        assertTrue(hook.getEpisode(0).resolved);

        // ExternalityAttributed must NOT be emitted
        bytes32 sig = keccak256("ExternalityAttributed(address,uint256,uint256)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == sig) {
                assertTrue(false, "ExternalityAttributed must not be emitted for zero RSPE");
            }
        }

        // No attribution stored
        assertEq(hook.getLPTotalExternality(address(lpA)), 0);
    }

    // =========================================================================
    // Edge case: manual fallback (Reactive never calls resolveEpisode)
    // =========================================================================

    /// @notice After 7 days with no Reactive callback, owner can manually resolve.
    function test_integration_manualFallback_afterTimeout() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _swap(1 ether);

        // Reactive never calls back — simulate by doing nothing

        // Before timeout: reverts
        vm.expectRevert(IExposureLedger.ManualTimeoutNotReached.selector);
        hook.manualResolveEpisode(0, EXTERNALITY, "fallback");

        // After timeout: succeeds
        uint256 createdAt = hook.getEpisode(0).createdTimestamp;
        vm.warp(createdAt + 7 days);

        hook.manualResolveEpisode(0, EXTERNALITY, "ipfs://QmFallback");

        assertTrue(hook.getEpisode(0).resolved);
        assertGt(hook.getLPTotalExternality(address(lpA)), 0);
    }

    // =========================================================================
    // Edge case: two swaps - two independent episodes
    // =========================================================================

    /// @notice Two sequential swaps create two independent episodes,
    ///         each resolved and attributed separately.
    function test_integration_twoEpisodes_resolvedIndependently() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);

        // Episode 0
        _swap(1 ether);
        reactive.resolveDirectly(address(hook), 0, EXTERNALITY);

        uint256 attrAfterEp0 = hook.getLPTotalExternality(address(lpA));
        assertGt(attrAfterEp0, 0);

        // Episode 1
        _swap(1 ether);
        reactive.resolveDirectly(address(hook), 1, EXTERNALITY / 2);

        uint256 attrAfterEp1 = hook.getLPTotalExternality(address(lpA));
        assertGt(attrAfterEp1, attrAfterEp0, "total must grow after second episode");

        // Per-episode records
        uint256 ep0 = hook.getLPEpisodeAttribution(address(lpA), 0);
        uint256 ep1 = hook.getLPEpisodeAttribution(address(lpA), 1);
        assertEq(attrAfterEp1, ep0 + ep1, "total must equal sum of episodes");
    }

    // =========================================================================
    // Edge case: LP adds AFTER swap (not exposed to that episode)
    // =========================================================================

    /// @notice An LP that adds liquidity AFTER a swap must not appear in that
    ///         episode's exposed list and must receive 0 attribution.
    function test_integration_lpAddsAfterSwap_notExposed() public {
        // Swap first - episode 0 created (only seedRouter in range)
        _swap(1 ether);

        // lpA adds AFTER the swap
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);

        reactive.resolveDirectly(address(hook), 0, EXTERNALITY);

        // lpA was not active at episode 0 time
        assertEq(hook.getLPEpisodeAttribution(address(lpA), 0), 0,
            "LP added after swap must not receive episode 0 attribution");
    }

    // =========================================================================
    // Edge case: double resolution attempt
    // =========================================================================

    /// @notice Reactive calling resolveEpisode twice must revert with
    ///         EpisodeAlreadyResolved on the second call.
    function test_integration_doubleResolution_reverts() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _swap(1 ether);

        reactive.resolveDirectly(address(hook), 0, EXTERNALITY);

        vm.expectRevert(IExposureLedger.EpisodeAlreadyResolved.selector);
        reactive.resolveDirectly(address(hook), 0, EXTERNALITY);
    }

    // =========================================================================
    // Edge case: RSPE via price-based MockReactive
    // =========================================================================

    /// @notice Resolve using the RSPE price formula in MockReactive.
    ///         When price doesn't move, RSPE = 0; when it moves, RSPE > 0.
    function test_integration_rspePriceFormula_nonZero() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _swap(1 ether);
        IExposureLedger.SwapEpisode memory ep = hook.getEpisode(0);

        // Register and roll forward
        reactive.onEpisodeCreated(0, ep.sqrtPriceX96, 1 ether);
        vm.roll(block.number + reactive.OBSERVATION_HORIZON() + 1);

        // Price moved 10% - RSPE > 0
        reactive.resolveWithRSPE(address(hook), 0, 1e18, 11e17);

        IExposureLedger.SwapEpisode memory resolved = hook.getEpisode(0);
        assertTrue(resolved.resolved);
        assertGt(resolved.externality, 0, "price moved - RSPE must be non-zero");
    }

    /// @notice When price doesn't move, RSPE = 0 - no attribution.
    function test_integration_rspePriceFormula_zeroWhenNoMove() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _swap(1 ether);
        IExposureLedger.SwapEpisode memory ep = hook.getEpisode(0);

        reactive.onEpisodeCreated(0, ep.sqrtPriceX96, 1 ether);
        vm.roll(block.number + reactive.OBSERVATION_HORIZON() + 1);

        // No price move - RSPE = 0
        reactive.resolveWithRSPE(address(hook), 0, 1e18, 1e18);

        assertEq(hook.getEpisode(0).externality, 0);
        assertEq(hook.getLPTotalExternality(address(lpA)), 0);
    }

    // =========================================================================
    // Task 6.3 — Gas benchmarks
    // =========================================================================

    /// @notice afterSwap gas benchmark (1 LP, typical case).
    function test_gas_afterSwap_oneLPInRange() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);

        uint256 before = gasleft();
        _swap(1 ether);
        uint256 used = before - gasleft();

        emit log_named_uint("afterSwap gas (1 LP)", used);
        assertTrue(used < 1_000_000, "afterSwap must be under 1M gas for 1 LP");
    }

    /// @notice resolveEpisode + attribution gas benchmark (1 LP).
    function test_gas_resolveEpisode_oneLPAttribution() public {
        _addLiq(lpA, LP_A_LIQ, tickLower, tickUpper);
        _swap(1 ether);

        uint256 before = gasleft();
        reactive.resolveDirectly(address(hook), 0, EXTERNALITY);
        uint256 used = before - gasleft();

        emit log_named_uint("resolveEpisode gas (1 LP)", used);
        assertTrue(used < 500_000, "resolveEpisode must be under 500k gas for 1 LP");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

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
