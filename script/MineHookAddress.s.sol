// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {ExposureLedgerHook} from "../src/ExposureLedgerHook.sol";

/// @title MineHookAddress
/// @notice Mines a CREATE2 salt to deploy ExposureLedgerHook at an address
///         whose lower bits encode its hook permissions.
///
/// IMPORTANT: Mines with the Nick/CREATE2 factory (0x4e59b...) as deployer
///            because DeployExposureLedger.s.sol sends raw calldata to that factory.
///
/// Usage (no broadcast):
///   forge script script/MineHookAddress.s.sol --rpc-url $SEPOLIA_RPC -vvvv
///
/// Then set CREATE2_SALT=<output> in .env and run DeployExposureLedger.s.sol
contract MineHookAddress is Script {
    // Nick/CREATE2 factory - what DeployExposureLedger.s.sol calls into
    // Inherited from forge-std Script (Base.sol) as CREATE2_FACTORY

    // Must exactly match ExposureLedgerHook.getHookPermissions()
    uint160 constant FLAGS =
        uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG) |
        uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG) |
        uint160(Hooks.AFTER_SWAP_FLAG);

    function run() external view {
        address poolManager = vm.envOr(
            "POOL_MANAGER_ADDRESS",
            address(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543) // Sepolia default
        );
        // The deployer wallet that will own the hook (must match --private-key signer)
        address deployerWallet = vm.envOr(
            "CLIENT_WALLET",
            address(0x1d2207f52782aaF69649a8c23EB9b9D83C2066ED) // from .env
        );

        console2.log("=== Mining Hook Address ===");
        console2.log("CREATE2 factory (deployer):", CREATE2_FACTORY);
        console2.log("PoolManager:               ", poolManager);
        console2.log("Deployer wallet (owner):   ", deployerWallet);
        console2.log("Required flags:            ", FLAGS);
        console2.log("Mining... (may take 30-120 seconds)");

        // Build the same initCode that DeployExposureLedger.s.sol will use
        bytes memory initCode = abi.encodePacked(
            type(ExposureLedgerHook).creationCode,
            abi.encode(IPoolManager(poolManager), deployerWallet)
        );

        // Mine: address = keccak(0xff ++ CREATE2_FACTORY ++ salt ++ keccak(initCode)) & FLAGS == FLAGS
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY,
            FLAGS,
            type(ExposureLedgerHook).creationCode,
            abi.encode(IPoolManager(poolManager), deployerWallet)
        );

        // Sanity check: computed address must match mined address
        address computed = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            CREATE2_FACTORY,
            salt,
            keccak256(initCode)
        )))));
        require(computed == hookAddress, "address sanity check failed");

        console2.log("");
        console2.log("=== Mining Complete ===");
        console2.log("Hook address:  ", hookAddress);
        console2.log("Salt (uint256):", uint256(salt));
        console2.log("");
        console2.log("Add to .env then deploy:");
        console2.log("  export CREATE2_SALT=<salt above>");
        console2.log("  forge script script/DeployExposureLedger.s.sol \\");
        console2.log("    --rpc-url $SEPOLIA_RPC --broadcast --verify -vvvv");
    }
}
