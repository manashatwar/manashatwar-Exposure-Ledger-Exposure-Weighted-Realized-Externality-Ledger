// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ---------------------------------------------------------------------------
// Reactive Network minimal interface stubs
// (The full SDK lives in reactive-smart-contract-demos/reactive-lib.
//  These stubs are sufficient for Foundry compilation and local simulation.
//  When deploying to Reactive Network, use the canonical AbstractReactive.)
// ---------------------------------------------------------------------------

/// @notice Minimum interface the Reactive Network expects from a reactive contract.
interface IReactive {
    /// @notice Called by the Reactive Network to deliver a subscribed event.
    function react(
        uint256 chainId,
        address emittingContract,
        bytes32 topic0,
        bytes32 topic1,
        bytes32 topic2,
        bytes32 topic3,
        bytes calldata data,
        uint256 blockNumber,
        uint256 opCode
    ) external;
}

/// @notice Minimal system contract interface used to subscribe to events.
interface ISystemContract {
    /// @notice Subscribe to a specific event topic from a contract on a chain.
    function subscribe(
        uint256 chainId,
        address emittingContract,
        bytes32 topic0,
        bytes32 topic1,
        bytes32 topic2,
        bytes32 topic3
    ) external;
}

/// @notice Minimal abstract base matching Reactive SDK's AbstractReactive.
///         Handles subscription in the constructor and guards the react callback.
abstract contract AbstractReactive is IReactive {
    /// @dev Address of the Reactive system contract (subscription manager).
    ISystemContract internal immutable SERVICE_ADDR;

    /// @dev On Reactive Network, msg.sender for react() is always the service address.
    ///      On local testnet, this can be relaxed for simulation.
    modifier onlyReactive() {
        require(
            msg.sender == address(SERVICE_ADDR) || address(SERVICE_ADDR) == address(0),
            "AbstractReactive: not reactive"
        );
        _;
    }

    constructor(address _serviceAddr) {
        SERVICE_ADDR = ISystemContract(_serviceAddr);
    }
}
