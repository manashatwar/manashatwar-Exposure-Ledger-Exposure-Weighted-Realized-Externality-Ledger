// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {Script, console2} from "forge-std/Script.sol";

import {ILFlowHook} from "../src/ILFlowHook.sol";

/// @notice Mines a valid Uniswap v4 hook address and deploys ILFlowHook with CREATE2.
contract DeployHookScript is Script {
    function run() public {
        address poolManagerAddress = vm.envAddress("POOL_MANAGER_ADDR");
        address callbackProxy = vm.envOr("DESTINATION_CALLBACK_PROXY_ADDR", address(0));

        // ILFlowHook uses beforeAddLiquidity, beforeRemoveLiquidity, and afterSwap.
        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        bytes memory constructorArgs = abi.encode(IPoolManager(poolManagerAddress));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(ILFlowHook).creationCode, constructorArgs);

        console2.log("Mined ILFlowHook address:", hookAddress);
        console2.logBytes32(salt);

        vm.startBroadcast();
        ILFlowHook hook = new ILFlowHook{salt: salt}(IPoolManager(poolManagerAddress));

        if (callbackProxy != address(0)) {
            hook.setOracle(callbackProxy);
            console2.log("Oracle set to callback proxy:", callbackProxy);
        }

        vm.stopBroadcast();

        require(address(hook) == hookAddress, "DeployHookScript: Hook address mismatch");
        console2.log("ILFlowHook deployed at:", address(hook));
    }
}
