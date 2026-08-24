// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract ILFlowHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct ILClaim {
        bytes32 poolId;
        address lp;
        address underwriter;
        uint160 entrySqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 maturityBlock;
        uint256 premiumBps;
        uint256 collateralLocked;
        bool active;
        bool settled;
    }

    mapping(uint256 => ILClaim) public claims;
    mapping(address => uint256[]) public lpClaims;
    mapping(address => uint256) public underwriterCollateral;
    mapping(address => uint256) public underwriterLockedCollateral;
    mapping(address => uint256) public underwriterEarnings;
    mapping(PoolId => uint256) public poolFairPremiumBps;
    mapping(PoolId => uint256) public poolRealizedVol;
    mapping(address => bool) private isRegisteredUnderwriter;
    mapping(address => uint256) public pendingPremium;

    uint256 public nextClaimId;
    address[] public registeredUnderwriters;
    address public pqsOracle;
    address public owner;

    uint256 public constant MIN_COLLATERAL = 0.01 ether;
    uint256 public constant COLLATERAL_RATIO = 150;
    uint256 public constant DEFAULT_PREMIUM_BPS = 300;

    event ClaimCreated(
        uint256 indexed claimId,
        address indexed lp,
        address indexed underwriter,
        uint256 premiumBps,
        uint256 maturityBlock
    );
    event ClaimSettled(uint256 indexed claimId, uint256 ilAmount, uint256 payout, bool slashed);
    event PriceTracked(PoolId indexed poolId, uint160 sqrtPriceX96, uint256 blockNumber);
    event UnderwriterStaked(address indexed underwriter, uint256 amount);
    event UnderwriterWithdrew(address indexed underwriter, uint256 amount);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        owner = msg.sender;
    }

    function setOracle(address _oracle) external {
        require(msg.sender == owner, "Not owner");
        require(pqsOracle == address(0), "Oracle already set");
        pqsOracle = _oracle;
    }

    function updatePoolMetrics(bytes32 rawPoolId, uint256 fairPremiumBps_, uint256 realizedVol) external {
        require(msg.sender == pqsOracle, "Only oracle can update");
        PoolId poolId = PoolId.wrap(rawPoolId);
        poolFairPremiumBps[poolId] = fairPremiumBps_;
        poolRealizedVol[poolId] = realizedVol;
    }

    function getClaimDetails(uint256 claimId) external view returns (ILClaim memory) {
        return claims[claimId];
    }

    function getPoolMetrics(PoolId poolId) external view returns (uint256 premium, uint256 vol) {
        return (poolFairPremiumBps[poolId], poolRealizedVol[poolId]);
    }

    /// @notice LP calls this to collect the upfront premium their underwriter paid at claim creation.
    function claimPremium() external {
        uint256 amount = pendingPremium[msg.sender];
        require(amount > 0, "No pending premium");
        pendingPremium[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "Transfer failed");
    }

    function stakeCollateral() external payable {
        require(msg.value >= MIN_COLLATERAL, "Insufficient collateral");

        if (!isRegisteredUnderwriter[msg.sender]) {
            isRegisteredUnderwriter[msg.sender] = true;
            registeredUnderwriters.push(msg.sender);
        }

        underwriterCollateral[msg.sender] += msg.value;

        emit UnderwriterStaked(msg.sender, msg.value);
    }

    function withdrawCollateral(uint256 amount) external {
        uint256 available = getAvailableCapacity(msg.sender);
        require(amount <= available, "Insufficient available collateral");

        underwriterCollateral[msg.sender] -= amount;

        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");

        emit UnderwriterWithdrew(msg.sender, amount);
    }

    function getAvailableCapacity(address underwriter) public view returns (uint256) {
        return underwriterCollateral[underwriter] - underwriterLockedCollateral[underwriter];
    }

    function _matchUnderwriter(uint256 requiredCollateral) internal view returns (address) {
        for (uint256 i; i < registeredUnderwriters.length; i++) {
            address underwriter = registeredUnderwriters[i];
            if (getAvailableCapacity(underwriter) >= requiredCollateral) {
                return underwriter;
            }
        }

        return address(0);
    }

    // ponytail: full-range V2 IL approximation (2√r/(1+r)); V3 concentrated-range amplification skipped.
    // Upgrade: apply range multiplier using tickLower/tickUpper when position is in-range.
    function _computeILRatio(uint160 entrySqrtPriceX96, uint160 exitSqrtPriceX96)
        internal
        pure
        returns (uint256 ilRatio)
    {
        if (exitSqrtPriceX96 == entrySqrtPriceX96) return 0;
        uint256 sqrtR = (uint256(exitSqrtPriceX96) * 1e18) / uint256(entrySqrtPriceX96);
        uint256 r = (sqrtR * sqrtR) / 1e18;
        uint256 denom = 1e18 + r;
        ilRatio = 1e18 - (2 * sqrtR * 1e18) / denom;
    }

    function _computeRequiredCollateral(uint128 liquidity, uint256) internal pure returns (uint256) {
        return (uint256(liquidity) * 2 * COLLATERAL_RATIO) / 10000;
    }

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

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    )
        internal
        override
        returns (bytes4)
    {
        if (hookData.length == 0) {
            return BaseHook.beforeAddLiquidity.selector;
        }

        (bool wantProtection, uint256 durationBlocks) = abi.decode(hookData, (bool, uint256));
        if (!wantProtection) {
            return BaseHook.beforeAddLiquidity.selector;
        }

        _createProtectedClaim(
            sender,
            key.toId(),
            params.tickLower,
            params.tickUpper,
            uint128(uint256(params.liquidityDelta)),
            durationBlocks
        );

        return BaseHook.beforeAddLiquidity.selector;
    }

    function _createProtectedClaim(
        address sender,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 durationBlocks
    ) internal {
        uint256 premiumBps = poolFairPremiumBps[poolId] > 0 ? poolFairPremiumBps[poolId] : DEFAULT_PREMIUM_BPS;
        uint256 requiredCollateral = _computeRequiredCollateral(liquidity, premiumBps);
        // ponytail: premium is flat % of collateral, not pro-rated by duration. Upgrade: scale by durationBlocks/BLOCKS_PER_YEAR.
        uint256 premiumAmount = (requiredCollateral * premiumBps) / 10000;
        address underwriter = _matchUnderwriter(requiredCollateral + premiumAmount);

        require(underwriter != address(0), "No underwriter available");

        uint256 claimId = nextClaimId;
        uint256 maturityBlock = block.number + durationBlocks;
        ILClaim storage claim = claims[claimId];

        claim.poolId = PoolId.unwrap(poolId);
        claim.lp = sender;
        claim.underwriter = underwriter;
        (claim.entrySqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        claim.tickLower = tickLower;
        claim.tickUpper = tickUpper;
        claim.liquidity = liquidity;
        claim.maturityBlock = maturityBlock;
        claim.premiumBps = premiumBps;
        claim.collateralLocked = requiredCollateral;
        claim.active = true;

        lpClaims[sender].push(claimId);
        underwriterLockedCollateral[underwriter] += requiredCollateral;
        // Premium leaves underwriter and sits in hook until LP calls claimPremium()
        underwriterCollateral[underwriter] -= premiumAmount;
        pendingPremium[sender] += premiumAmount;
        nextClaimId = claimId + 1;

        emit ClaimCreated(claimId, sender, underwriter, premiumBps, maturityBlock);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        emit PriceTracked(poolId, sqrtPriceX96, block.number);

        return (BaseHook.afterSwap.selector, 0);
    }

    function _beforeRemoveLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        (bool found, uint256 claimId) = _findActiveClaim(sender, poolId);

        if (!found) {
            return BaseHook.beforeRemoveLiquidity.selector;
        }

        _settleClaim(poolId, claimId);

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _findActiveClaim(address lp, PoolId poolId) internal view returns (bool found, uint256 claimId) {
        uint256[] storage claimIds = lpClaims[lp];
        bytes32 rawPoolId = PoolId.unwrap(poolId);

        for (uint256 i; i < claimIds.length; i++) {
            uint256 currentClaimId = claimIds[i];
            ILClaim storage claim = claims[currentClaimId];

            if (claim.active && claim.poolId == rawPoolId) {
                return (true, currentClaimId);
            }
        }

        return (false, 0);
    }

    function _settleClaim(PoolId poolId, uint256 claimId) internal {
        ILClaim storage claim = claims[claimId];
        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint256 ilRatio = _computeILRatio(claim.entrySqrtPriceX96, currentSqrtPriceX96);
        // Payout is the IL ratio applied to locked collateral (capped at collateralLocked by construction)
        uint256 payout = (claim.collateralLocked * ilRatio) / 1e18;

        // Always release the lock first
        underwriterLockedCollateral[claim.underwriter] -= claim.collateralLocked;

        if (payout > 0) {
            underwriterCollateral[claim.underwriter] -= payout;
            payable(claim.lp).transfer(payout);
            emit ClaimSettled(claimId, ilRatio, payout, true);
        } else {
            emit ClaimSettled(claimId, 0, 0, false);
        }

        claim.active = false;
        claim.settled = true;
    }
}
