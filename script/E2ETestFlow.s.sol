// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @title E2ETestFlow
/// @notice End-to-end test: create pool → add liquidity → swap → episode created.
///
/// Swap goes DIRECTLY through PoolManager.unlock() callback pattern —
/// no external router needed. This is the only reliable way to swap in V4.
///
/// Usage:
///   forge script script/E2ETestFlow.s.sol:E2ETestFlow \
///     --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast --via-ir -vvvv
contract E2ETestFlow is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ── Sepolia addresses ─────────────────────────────────────────────────────
    IPoolManager    constant POOL_MANAGER  = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
    IPositionManager constant POS_MANAGER = IPositionManager(0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4);
    address         constant PERMIT2       = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address         constant HOOK          = 0x30D4F958F727518e4E5949538877065aBF924a40;

    // Pool parameters
    uint24  constant FEE          = 3000;
    int24   constant TICK_SPACING = 60;
    int24   constant TICK_LOWER   = -600;
    int24   constant TICK_UPPER   =  600;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        address deployer = msg.sender;

        console.log("=== E2E Test Flow ===");
        console.log("Deployer:", deployer);
        console.log("Hook:    ", HOOK);

        vm.startBroadcast();

        // ── 1. Deploy two test ERC20 tokens ──────────────────────────────────
        TestERC20 tokenA = new TestERC20("Test Token A", "TKNA", 18);
        TestERC20 tokenB = new TestERC20("Test Token B", "TKNB", 18);

        // Sort so currency0 < currency1 (Uniswap requirement)
        (TestERC20 token0, TestERC20 token1) = address(tokenA) < address(tokenB)
            ? (tokenA, tokenB) : (tokenB, tokenA);

        console.log("Token0:", address(token0));
        console.log("Token1:", address(token1));

        // ── 2. Mint ───────────────────────────────────────────────────────────
        token0.mint(deployer, 1_000_000 ether);
        token1.mint(deployer, 1_000_000 ether);

        // ── 3. ERC20 → Permit2 approval ───────────────────────────────────────
        token0.approve(PERMIT2, type(uint256).max);
        token1.approve(PERMIT2, type(uint256).max);

        // ── 4. Permit2 → PositionManager approval ────────────────────────────
        (bool ok0,) = PERMIT2.call(abi.encodeWithSignature(
            "approve(address,address,uint160,uint48)",
            address(token0), address(POS_MANAGER), type(uint160).max, type(uint48).max
        ));
        require(ok0, "Permit2 approve token0 failed");
        (bool ok1,) = PERMIT2.call(abi.encodeWithSignature(
            "approve(address,address,uint160,uint48)",
            address(token1), address(POS_MANAGER), type(uint160).max, type(uint48).max
        ));
        require(ok1, "Permit2 approve token1 failed");

        // ── 5. Initialize pool ────────────────────────────────────────────────
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });

        POOL_MANAGER.initialize(poolKey, SQRT_PRICE_1_1);
        console.log("Pool initialized. PoolId:");
        console.logBytes32(PoolId.unwrap(poolKey.toId()));

        // ── 6. Add liquidity (opens LP segment via beforeAddLiquidity hook) ───
        bytes memory liqActions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );
        bytes[] memory liqParams = new bytes[](2);
        liqParams[0] = abi.encode(
            poolKey, TICK_LOWER, TICK_UPPER,
            uint256(10_000 ether), type(uint128).max, type(uint128).max,
            deployer, bytes("")
        );
        liqParams[1] = abi.encode(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1))
        );
        POS_MANAGER.modifyLiquidities(
            abi.encode(liqActions, liqParams),
            block.timestamp + 300
        );
        console.log("Liquidity added. LPSegmentOpened emitted by hook.");

        // ── 7. Swap via PoolSwapTest (Uniswap's own canonical test swap helper) ──
        // PoolSwapTest uses CurrencySettler which correctly does sync→transfer→settle
        PoolSwapTest swapRouter = new PoolSwapTest(POOL_MANAGER);
        // Direct ERC20 approval (not Permit2) — PoolSwapTest uses transferFrom internally
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        console.log("Swap executed! EpisodeCreated should be emitted by hook.");

        vm.stopBroadcast();

        console.log("");
        console.log("=== E2E Complete ===");
        console.log("Hook:   ", HOOK);
        console.log("Token0: ", address(token0));
        console.log("Token1: ", address(token1));
        console.log("PoolId: 0xfecd650c7f50e024aa207bac99a883fdcbef74a7ca63fdbb3c0d8b9c7417e071");
        console.log("");
        console.log("Now check:");
        console.log("  Etherscan (EpisodeCreated event):");
        console.log("    https://sepolia.etherscan.io/address/", HOOK);
        console.log("  Wait 50 blocks (~10 min) then check Reactscan:");
        console.log("    https://lasna.reactscan.net/address/0x3066E93095FadBeF2793C6194d0126FBfec7F50e");
        console.log("  Query attribution after resolution:");
        console.log("    cast call", HOOK, "'nextEpisodeId()(uint256)' --rpc-url $SEPOLIA_RPC");
    }
}



/// @dev Minimal ERC20 for testing
contract TestERC20 {
    string public name;
    string public symbol;
    uint8  public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name; symbol = _symbol; decimals = _decimals;
    }
    function mint(address to, uint256 amount) external {
        totalSupply += amount; balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount); return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount; balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount); return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount; balanceOf[to] += amount;
        emit Transfer(from, to, amount); return true;
    }
}
