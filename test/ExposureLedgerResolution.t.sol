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
import {MockReferencePriceOracle} from "./mocks/MockReferencePriceOracle.sol";

/// @dev Minimal payable liquidity router for test infrastructure.
contract PayableRouter is PoolModifyLiquidityTest {
    constructor(IPoolManager manager) PoolModifyLiquidityTest(manager) {}
    receive() external payable {}
}

/// @title ExposureLedgerResolutionTest
/// @notice Unit tests for episode resolution — the core mechanism by which the
///         Reactive Network (or the owner as a fallback) finalises RSPE values
///         and triggers LP attribution.
///
/// Coverage
/// ─────────
///   § resolveEpisode  (Task 3.2)
///       • Authorization  — only reactiveCallbackProxy may call
///       • Double-resolve — EpisodeAlreadyResolved guard
///       • State          — externality + resolved flag written correctly
///       • Events         — EpisodeResolved emitted with correct indexed fields
///       • Attribution    — runs proportionally; sum invariant holds
///       • Edge cases     — zero externality, multiple episodes, unexposed LP
///
///   § manualResolveEpisode  (Task 3.3)
///       • Timeout        — ManualTimeoutNotReached before 7 days
///       • Boundary       — works at exactly 7 days and 30 days later
///       • Authorization  — onlyOwner (proxy, random both reverted)
///       • Double-resolve — revert on both auto-then-manual and manual-then-manual
///       • Events         — EpisodeResolved + ManualResolution both emitted
///       • Attribution    — triggered correctly after manual resolution
///
///   § setReactiveCallbackProxy (admin)
///       • One-time set, owner-only
///
/// Oracle: Chainlink (see src/oracle/ChainlinkPriceOracle.sol).
/// For unit tests, MockReferencePriceOracle is used in its place.
contract ExposureLedgerResolutionTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    // -------------------------------------------------------------------------
    // Test state
    // -------------------------------------------------------------------------
    ExposureLedgerHook public hook;
    MockReferencePriceOracle public oracle;

    PayableRouter public seedRouter;  /// Seeds pool depth; segments tracked under seedRouter
    PayableRouter public lpRouter;    /// LP under test; starts with zero segments

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    PoolId poolId;

    address public proxy    = makeAddr("reactive_proxy");
    address public nonOwner = makeAddr("nonOwner");

    int24 tickLower;
    int24 tickUpper;
    uint128 constant SEED_LIQ   = 100e18;
    uint128 constant LP_LIQ     = 10e18;
    uint256 constant EXTERNALITY = 1 ether;

    uint160 constant HOOK_FLAGS =
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
        Hooks.AFTER_SWAP_FLAG           |
        Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------
    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        // Deploy hook at flag-encoded address
        address hookAddr = address(uint160(HOOK_FLAGS) ^ (0x4444 << 144));
        deployCodeTo("ExposureLedgerHook.sol:ExposureLedgerHook", abi.encode(poolManager, address(this)), hookAddr);
        hook = ExposureLedgerHook(hookAddr);

        // Authorise the reactive proxy
        hook.setReactiveCallbackProxy(proxy);

        // Initialise pool
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId  = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        oracle = new MockReferencePriceOracle();

        // Pool depth via seedRouter (isolated address — never queried in assertions)
        seedRouter = new PayableRouter(poolManager);
        MockERC20(Currency.unwrap(currency0)).approve(address(seedRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(seedRouter), type(uint256).max);
        _modifyLiq(seedRouter, int256(uint256(SEED_LIQ)), tickLower, tickUpper);

        // LP liquidity via lpRouter (the address whose attribution we verify)
        lpRouter = new PayableRouter(poolManager);
        MockERC20(Currency.unwrap(currency0)).approve(address(lpRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(lpRouter), type(uint256).max);
        _modifyLiq(lpRouter, int256(uint256(LP_LIQ)), tickLower, tickUpper);

        // Perform a swap - creates episode 0
        swapRouter.swapExactTokensForTokens({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(hook.nextEpisodeId(), 1, "setUp: expected exactly 1 episode");
    }

    // =========================================================================
    // § resolveEpisode — Authorization
    // =========================================================================

    /// @notice A random non-proxy caller must revert with UnauthorizedResolver.
    function test_resolveEpisode_revertsUnauthorized() public {
        vm.prank(nonOwner);
        vm.expectRevert(IExposureLedger.UnauthorizedResolver.selector);
        hook.resolveEpisode(0, EXTERNALITY);
    }

    /// @notice The owner (who is NOT the proxy) must also revert.
    function test_resolveEpisode_revertsOwnerNotProxy() public {
        // owner == address(this) in tests; proxy == separate address
        vm.expectRevert(IExposureLedger.UnauthorizedResolver.selector);
        hook.resolveEpisode(0, EXTERNALITY);
    }

    // =========================================================================
    // § resolveEpisode — Double-resolve guard
    // =========================================================================

    /// @notice Resolving the same episode twice must revert with EpisodeAlreadyResolved.
    function test_resolveEpisode_revertsAlreadyResolved() public {
        vm.prank(proxy);
        hook.resolveEpisode(0, EXTERNALITY);

        vm.prank(proxy);
        vm.expectRevert(IExposureLedger.EpisodeAlreadyResolved.selector);
        hook.resolveEpisode(0, EXTERNALITY);
    }

    // =========================================================================
    // § resolveEpisode — State changes
    // =========================================================================

    /// @notice resolveEpisode must persist the externality value on the episode.
    function test_resolveEpisode_setsExternality() public {
        vm.prank(proxy);
        hook.resolveEpisode(0, EXTERNALITY);

        assertEq(hook.getEpisode(0).externality, EXTERNALITY);
    }

    /// @notice resolveEpisode must flip the resolved flag to true.
    function test_resolveEpisode_marksResolved() public {
        assertFalse(hook.getEpisode(0).resolved, "must be unresolved initially");

        vm.prank(proxy);
        hook.resolveEpisode(0, EXTERNALITY);

        assertTrue(hook.getEpisode(0).resolved);
    }

    /// @notice externality = 0 still resolves the episode (attribution skipped internally).
    function test_resolveEpisode_zeroExternality_stillResolves() public {
        vm.prank(proxy);
        hook.resolveEpisode(0, 0);

        IExposureLedger.SwapEpisode memory ep = hook.getEpisode(0);
        assertTrue(ep.resolved);
        assertEq(ep.externality, 0);
    }

    // =========================================================================
    // § resolveEpisode — Events
    // =========================================================================

    /// @notice EpisodeResolved must be emitted with correct indexed episodeId.
    function test_resolveEpisode_emitsEpisodeResolved() public {
        vm.recordLogs();
        vm.prank(proxy);
        hook.resolveEpisode(0, EXTERNALITY);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertEmitted(logs, keccak256("EpisodeResolved(uint256,uint256,uint256)"), 0, "EpisodeResolved");
    }

    // =========================================================================
    // § resolveEpisode — Attribution
    // =========================================================================

    /// @notice Attribution must run and set a positive total for the exposed LP.
    function test_resolveEpisode_triggersAttribution() public {
        vm.prank(proxy);
        hook.resolveEpisode(0, EXTERNALITY);

        assertGt(hook.getLPTotalExternality(address(lpRouter)), 0, "exposed LP must get attribution");
    }

    /// @notice Sum of all LP attributions must not exceed episode externality.
    function test_resolveEpisode_attributionDoesNotExceedExternality() public {
        vm.prank(proxy);
        hook.resolveEpisode(0, EXTERNALITY);

        uint256 total =
            hook.getLPTotalExternality(address(lpRouter)) +
            hook.getLPTotalExternality(address(seedRouter));

        assertLe(total, EXTERNALITY, "sum of attributions must be <= externality");
    }

    /// @notice Per-episode attribution stored via getLPEpisodeAttribution must match total.
    function test_resolveEpisode_perEpisodeAttribution() public {
        vm.prank(proxy);
        hook.resolveEpisode(0, EXTERNALITY);

        uint256 perEp    = hook.getLPEpisodeAttribution(address(lpRouter), 0);
        uint256 perTotal = hook.getLPTotalExternality(address(lpRouter));
        assertEq(perEp, perTotal, "single-episode total must equal per-episode record");
    }

    /// @notice LP not registered in episodeExposedLPs must receive zero attribution.
    function test_resolveEpisode_unexposedLP_getsZero() public {
        address rando = makeAddr("rando");

        vm.prank(proxy);
        hook.resolveEpisode(0, EXTERNALITY);

        assertEq(hook.getLPTotalExternality(rando), 0, "unexposed LP must get zero");
    }

    /// @notice Resolving multiple episodes accumulates total externality correctly.
    function test_resolveEpisode_multipleEpisodes_accumulates() public {
        // Create episode 1
        swapRouter.swapExactTokensForTokens({
            amountIn: 0.5 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        assertEq(hook.nextEpisodeId(), 2);

        vm.prank(proxy);
        hook.resolveEpisode(0, EXTERNALITY);

        vm.prank(proxy);
        hook.resolveEpisode(1, EXTERNALITY / 2);

        uint256 ep0   = hook.getLPEpisodeAttribution(address(lpRouter), 0);
        uint256 ep1   = hook.getLPEpisodeAttribution(address(lpRouter), 1);
        uint256 total = hook.getLPTotalExternality(address(lpRouter));
        assertEq(total, ep0 + ep1, "total must be sum of individual episode attributions");
    }

    // =========================================================================
    // § manualResolveEpisode — Timeout enforcement
    // =========================================================================

    /// @notice Owner cannot manually resolve before the 7-day timeout.
    function test_manualResolve_revertsBeforeTimeout() public {
        vm.expectRevert(IExposureLedger.ManualTimeoutNotReached.selector);
        hook.manualResolveEpisode(0, EXTERNALITY, "");
    }

    /// @notice One second before the deadline must still revert.
    function test_manualResolve_revertsJustBeforeTimeout() public {
        uint256 created = hook.getEpisode(0).createdTimestamp;
        vm.warp(created + 7 days - 1);

        vm.expectRevert(IExposureLedger.ManualTimeoutNotReached.selector);
        hook.manualResolveEpisode(0, EXTERNALITY, "");
    }

    /// @notice Owner can resolve at exactly the 7-day mark.
    function test_manualResolve_worksAtExactTimeout() public {
        uint256 created = hook.getEpisode(0).createdTimestamp;
        vm.warp(created + 7 days);

        hook.manualResolveEpisode(0, EXTERNALITY, "evidence");

        IExposureLedger.SwapEpisode memory ep = hook.getEpisode(0);
        assertTrue(ep.resolved);
        assertEq(ep.externality, EXTERNALITY);
    }

    /// @notice Owner can resolve well after the timeout (e.g. 30 days).
    function test_manualResolve_worksLongAfterTimeout() public {
        uint256 created = hook.getEpisode(0).createdTimestamp;
        vm.warp(created + 30 days);

        hook.manualResolveEpisode(0, 500, "ipfs://QmAbc");

        assertEq(hook.getEpisode(0).externality, 500);
        assertTrue(hook.getEpisode(0).resolved);
    }

    // =========================================================================
    // § manualResolveEpisode — Authorization
    // =========================================================================

    /// @notice A random non-owner cannot manually resolve even after timeout.
    function test_manualResolve_revertsNonOwner() public {
        uint256 created = hook.getEpisode(0).createdTimestamp;
        vm.warp(created + 7 days);

        vm.prank(nonOwner);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        hook.manualResolveEpisode(0, EXTERNALITY, "");
    }

    /// @notice The reactive proxy (not owner) cannot manually resolve.
    function test_manualResolve_revertsProxy() public {
        uint256 created = hook.getEpisode(0).createdTimestamp;
        vm.warp(created + 7 days);

        vm.prank(proxy);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        hook.manualResolveEpisode(0, EXTERNALITY, "");
    }

    // =========================================================================
    // § manualResolveEpisode — Double-resolve guard
    // =========================================================================

    /// @notice Auto-resolved episode cannot be manually resolved.
    function test_manualResolve_revertsAfterAutoResolve() public {
        vm.prank(proxy);
        hook.resolveEpisode(0, EXTERNALITY);

        uint256 created = hook.getEpisode(0).createdTimestamp;
        vm.warp(created + 7 days);

        vm.expectRevert(IExposureLedger.EpisodeAlreadyResolved.selector);
        hook.manualResolveEpisode(0, EXTERNALITY, "");
    }

    /// @notice Cannot manually resolve the same episode twice.
    function test_manualResolve_revertsDoubleManual() public {
        uint256 created = hook.getEpisode(0).createdTimestamp;
        vm.warp(created + 7 days);

        hook.manualResolveEpisode(0, EXTERNALITY, "first");

        vm.expectRevert(IExposureLedger.EpisodeAlreadyResolved.selector);
        hook.manualResolveEpisode(0, EXTERNALITY, "second");
    }

    // =========================================================================
    // § manualResolveEpisode — Events
    // =========================================================================

    /// @notice Both EpisodeResolved and ManualResolution must be emitted.
    function test_manualResolve_emitsBothEvents() public {
        uint256 created = hook.getEpisode(0).createdTimestamp;
        vm.warp(created + 7 days);

        vm.recordLogs();
        hook.manualResolveEpisode(0, EXTERNALITY, "ipfs://QmTest");
        // Capture ONCE — vm.getRecordedLogs() clears the buffer on each call
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertEmitted(logs, keccak256("EpisodeResolved(uint256,uint256,uint256)"),   0, "EpisodeResolved");
        _assertEmitted(logs, keccak256("ManualResolution(uint256,uint256,bytes)"),    0, "ManualResolution");
    }

    /// @notice ManualResolution must carry the correct indexed episodeId.
    function test_manualResolve_emitsCorrectEpisodeId() public {
        uint256 created = hook.getEpisode(0).createdTimestamp;
        vm.warp(created + 7 days);

        vm.recordLogs();
        hook.manualResolveEpisode(0, 42 ether, "proof");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertEmitted(logs, keccak256("ManualResolution(uint256,uint256,bytes)"), 0, "ManualResolution");
    }

    // =========================================================================
    // § manualResolveEpisode — Attribution
    // =========================================================================

    /// @notice Attribution must run and accumulate correctly after manual resolution.
    function test_manualResolve_triggersAttribution() public {
        uint256 created = hook.getEpisode(0).createdTimestamp;
        vm.warp(created + 7 days);

        hook.manualResolveEpisode(0, EXTERNALITY, "");

        assertGt(hook.getLPTotalExternality(address(lpRouter)), 0, "attribution must run");
    }

    // =========================================================================
    // § setReactiveCallbackProxy — Admin
    // =========================================================================

    /// @notice Proxy can only be set once; second call reverts.
    function test_setProxy_revertsIfAlreadySet() public {
        vm.expectRevert("Proxy already set");
        hook.setReactiveCallbackProxy(makeAddr("another"));
    }

    /// @notice Only the owner may set the proxy.
    function test_setProxy_revertsNonOwner() public {
        address freshAddr = address(uint160(HOOK_FLAGS) ^ (0x5555 << 144));
        deployCodeTo("ExposureLedgerHook.sol:ExposureLedgerHook", abi.encode(poolManager, address(this)), freshAddr);
        ExposureLedgerHook freshHook = ExposureLedgerHook(freshAddr);

        vm.prank(nonOwner);
        vm.expectRevert();
        freshHook.setReactiveCallbackProxy(proxy);
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Writes an LP address into episodeExposedLPs[episodeId] using vm.store.
    ///
    ///      Storage layout:
    ///        episodeExposedLPs is the 7th declared variable in ExposureLedgerHook
    ///        (Ownable._owner=0, episodes=1, nextEpisodeId=2, lpSegments=3,
    ///         lpTotalExternality=4, lpEpisodeAttribution=5, episodeExposedLPs=6)
    ///
    ///        mapping value slot  = keccak256(abi.encode(episodeId, 6))
    ///        array length stored at that slot
    ///        array[i] stored at  = keccak256(abi.encode(mappingSlot)) + i
    function _addToExposedLPs(uint256 episodeId, address lp) internal {
        bytes32 mappingSlot = keccak256(abi.encode(episodeId, uint256(6)));
        uint256 len         = uint256(vm.load(address(hook), mappingSlot));
        vm.store(address(hook), mappingSlot, bytes32(len + 1));

        bytes32 dataStart = keccak256(abi.encode(mappingSlot));
        bytes32 elemSlot  = bytes32(uint256(dataStart) + len);
        vm.store(address(hook), elemSlot, bytes32(uint256(uint160(lp))));
    }

    /// @dev Assert that a specific event was emitted by the hook with a given indexed topic[1].
    ///      Accepts pre-captured logs to avoid consuming the buffer on repeated calls
    ///      (vm.getRecordedLogs() clears the buffer each time it is called).
    function _assertEmitted(
        Vm.Log[] memory logs,
        bytes32 eventSig,
        uint256 expectedTopic1,
        string memory label
    ) internal {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] != eventSig) continue;
            if (logs[i].topics.length > 1) {
                assertEq(uint256(logs[i].topics[1]), expectedTopic1, label);
            }
            return; // found
        }
        assertTrue(false, string.concat(label, " not emitted"));
    }

    function _modifyLiq(PayableRouter router, int256 delta, int24 lower, int24 upper) internal {
        router.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: delta, salt: bytes32(0)}),
            Constants.ZERO_BYTES
        );
    }

    receive() external payable {}
}
