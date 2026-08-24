// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IReferencePriceOracle
/// @notice Oracle interface consumed by ExposureLedgerRSC to fetch reference prices
///         at the swap block and at the post-observation-horizon block.
///
/// @dev On Reactive Network mainnet, this will be a live Chainlink / Uniswap TWAP oracle.
///      For testing, `MockReferencePriceOracle` (in test/mocks/) implements this interface.
interface IReferencePriceOracle {
    /// @notice Returns the token0/token1 reference price at a specific block for a pool.
    /// @param poolId     Uniswap v4 PoolId (bytes32)
    /// @param blockNumber The block at which to fetch the price
    /// @return price     Price expressed as token1 per token0 (18-decimal fixed-point)
    /// @return timestamp Block timestamp at that block
    function getPriceAtBlock(bytes32 poolId, uint256 blockNumber)
        external
        view
        returns (uint256 price, uint256 timestamp);
}
