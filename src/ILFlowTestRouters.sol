// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @notice Testnet-only helper that lets an EOA exercise PoolManager.modifyLiquidity.
contract ILFlowTestModifyLiquidityRouter is PoolModifyLiquidityTest {
    constructor(IPoolManager manager) PoolModifyLiquidityTest(manager) {}

    receive() external payable {}
}

/// @notice Testnet-only helper that lets an EOA exercise PoolManager.swap.
contract ILFlowTestSwapRouter is PoolSwapTest {
    constructor(IPoolManager manager) PoolSwapTest(manager) {}

    receive() external payable {}
}
