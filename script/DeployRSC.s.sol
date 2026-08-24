// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ExposureLedgerRSC} from "../src/reactive/ExposureLedgerRSC.sol";

/// @title DeployRSC
/// @notice Deploys ExposureLedgerRSC to Reactive Network
contract DeployRSC is Script {
    function run() external {
        // Load from .env
        uint256 originChainId = vm.envUint("ORIGIN_CHAIN_ID");
        uint256 destinationChainId = vm.envUint("DESTINATION_CHAIN_ID");
        address hookAddr = vm.envAddress("HOOK_ADDR");
        address relayerAddr = vm.envAddress("RELAYER_ADDR");
        
        console.log("Deploying ExposureLedgerRSC to Reactive Network");
        console.log("  Origin Chain ID:    ", originChainId);
        console.log("  Destination Chain:  ", destinationChainId);
        console.log("  Hook Address:       ", hookAddr);
        console.log("  Relayer Address:    ", relayerAddr);
        console.log("  Deployer:           ", msg.sender);
        console.log("");

        vm.startBroadcast();

        // Deploy RSC with initial funding (0.1 REACT)
        ExposureLedgerRSC rsc = new ExposureLedgerRSC{value: 0.1 ether}(
            originChainId,
            destinationChainId,
            hookAddr,
            relayerAddr
        );

        console.log("ExposureLedgerRSC deployed at:", address(rsc));

        vm.stopBroadcast();

        console.log("");
        console.log("=== RSC Deployment Complete ===");
        console.log("RSC Address: ", address(rsc));
        console.log("");
        console.log("Next Steps:");
        console.log("1. Update .env with RSC_ADDR=", address(rsc));
        console.log("2. Connect RSC to hook:");
        console.log("   cast send", hookAddr);
        console.log("     'setReactiveCallbackProxy(address)'");
        console.log("     ", address(rsc));
        console.log("     --rpc-url $DESTINATION_RPC");
        console.log("     --private-key $DESTINATION_PRIVATE_KEY");
    }
}
