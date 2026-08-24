// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IReferencePriceOracle} from "../../src/interfaces/IReferencePriceOracle.sol";

/// @notice Configurable mock oracle for unit tests.
///         Stores prices per (poolId, blockNumber) and falls back to a per-poolId
///         default when no exact-block entry exists.
contract MockReferencePriceOracle is IReferencePriceOracle {
    /// @dev Exact block lookup: poolId - blockNumber - price
    mapping(bytes32 => mapping(uint256 => uint256)) private _prices;

    /// @dev Default price per poolId when no block-exact entry exists
    mapping(bytes32 => uint256) private _defaults;

    // -------------------------------------------------------------------------
    // Setters (test helpers)
    // -------------------------------------------------------------------------

    /// @notice Set a price for a specific pool at a specific block.
    function setPrice(bytes32 poolId, uint256 blockNumber, uint256 price) external {
        _prices[poolId][blockNumber] = price;
    }

    /// @notice Set a default price for a pool (returned when no exact-block entry).
    function setDefaultPrice(bytes32 poolId, uint256 price) external {
        _defaults[poolId] = price;
    }

    // -------------------------------------------------------------------------
    // IReferencePriceOracle
    // -------------------------------------------------------------------------

    function getPriceAtBlock(bytes32 poolId, uint256 blockNumber)
        external
        view
        override
        returns (uint256 price, uint256 timestamp)
    {
        uint256 exact = _prices[poolId][blockNumber];
        price = exact != 0 ? exact : _defaults[poolId];
        timestamp = block.timestamp; // simplified for tests
    }
}
