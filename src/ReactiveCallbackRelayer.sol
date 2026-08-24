// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IExposureLedger {
    function resolveEpisode(uint256 episodeId, uint256 externality) external;
}

/// @title ReactiveCallbackRelayer
/// @notice Receives callbacks from Reactive Network and forwards them to the Hook.
/// @dev Reactive Network RELAYERS forcefully overwrite the first 32 bytes of 
///      the callback payload with the RSC address (`address sender`).
///      Since the original hook expects `episodeId` as the first argument, 
///      the relayer was corrupting `episodeId` and causing silent reverts.
contract ReactiveCallbackRelayer {
    address public immutable hook;
    address public reactiveSystemProxy; // 0x0000000000000000000000000000000000fffFfF

    constructor(address _hook, address _reactiveSystemProxy) {
        hook = _hook;
        reactiveSystemProxy = _reactiveSystemProxy;
    }

    /// @notice Target for the Reactive Network callback
    function resolveEpisode(address sender, uint256 episodeId, uint256 rspe) external {
        require(msg.sender == reactiveSystemProxy, "Only Reactive Proxy");
        
        // Forward the clean parameters to the actual Hook
        IExposureLedger(hook).resolveEpisode(episodeId, rspe);
    }
}
