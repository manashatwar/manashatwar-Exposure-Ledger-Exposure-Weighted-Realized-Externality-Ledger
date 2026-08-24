// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IExposureLedger} from "../../src/interfaces/IExposureLedger.sol";

/// @title MockReactive
/// @notice Simulates the Reactive Network RSC for integration testing.
///
/// Capabilities
/// ─────────────
///   1. Stores pending episodes received via onEpisodeCreated().
///   2. resolveWithRSPE() computes min(D, A) using injected oracle prices
///      and calls hook.resolveEpisode() — mirroring ExposureLedgerRSC logic.
///   3. Exposes helpers for time/block manipulation in tests.
///
/// Usage in tests
/// ──────────────
///   1. Deploy MockReactive.
///   2. Call hook.setReactiveCallbackProxy(address(mockReactive)).
///   3. After a swap, call mockReactive.onEpisodeCreated(episodeId, sqrtPriceX96, ...).
///   4. Roll forward H blocks.
///   5. Call mockReactive.resolveWithRSPE(hook, episodeId, priceAtD, priceAtA)
///      — this calls hook.resolveEpisode(episodeId, rspe).
contract MockReactive {
    // -------------------------------------------------------------------------
    // RSPE constants (mirrors ExposureLedgerRSC)
    // -------------------------------------------------------------------------
    uint256 public constant OBSERVATION_HORIZON  = 50;   // blocks
    uint256 public constant PRICE_PRECISION      = 1e18;

    // -------------------------------------------------------------------------
    // Pending episode registry
    // -------------------------------------------------------------------------
    struct PendingEpisode {
        uint256 createdBlock;
        uint160 sqrtPriceX96AtCreation;
        uint256 amount0Abs;   // |delta.amount0| at swap time (stale opportunity proxy)
        bool    exists;
    }

    mapping(uint256 => PendingEpisode) public pending;

    // -------------------------------------------------------------------------
    // State-mutation helpers (called by test, not by hook)
    // -------------------------------------------------------------------------

    /// @notice Record a pending episode (called from test after swap).
    function onEpisodeCreated(
        uint256 episodeId,
        uint160 sqrtPriceX96,
        uint256 amount0Abs
    ) external {
        pending[episodeId] = PendingEpisode({
            createdBlock: block.number,
            sqrtPriceX96AtCreation: sqrtPriceX96,
            amount0Abs: amount0Abs,
            exists: true
        });
    }

    // -------------------------------------------------------------------------
    // Resolution
    // -------------------------------------------------------------------------

    /// @notice Resolve an episode using injected "oracle" prices.
    ///         Computes RSPE = min(D, A) and calls hook.resolveEpisode().
    ///
    /// @param hook        ExposureLedgerHook address.
    /// @param episodeId   Episode to resolve.
    /// @param priceAtD    18-decimal price at episode creation block (D boundary).
    /// @param priceAtA    18-decimal price H blocks later (A boundary).
    function resolveWithRSPE(
        address hook,
        uint256 episodeId,
        uint256 priceAtD,
        uint256 priceAtA
    ) external {
        require(pending[episodeId].exists, "MockReactive: episode not registered");

        IExposureLedger.SwapEpisode memory ep = IExposureLedger(hook).getEpisode(episodeId);

        // D = stale-opportunity cost ~ |amount0| * |priceAtA - priceAtD| / priceAtD
        uint256 priceMove = priceAtA > priceAtD
            ? priceAtA - priceAtD
            : priceAtD - priceAtA;
        uint256 storedAmount0 = pending[episodeId].amount0Abs;
        uint256 D = priceAtD > 0 ? (storedAmount0 * priceMove) / priceAtD : 0;

        // A = adverse markout (symmetric approximation for mock)
        uint256 A = D;

        uint256 rspe = D < A ? D : A;

        IExposureLedger(hook).resolveEpisode(episodeId, rspe);
    }

    /// @notice Resolve with a direct externality value (bypass RSPE formula).
    ///         Useful for testing attribution without price math.
    function resolveDirectly(address hook, uint256 episodeId, uint256 externality) external {
        IExposureLedger(hook).resolveEpisode(episodeId, externality);
    }

    /// @notice Check if the observation horizon has passed for an episode.
    function horizonReached(uint256 episodeId) external view returns (bool) {
        PendingEpisode storage ep = pending[episodeId];
        return ep.exists && block.number >= ep.createdBlock + OBSERVATION_HORIZON;
    }
}
