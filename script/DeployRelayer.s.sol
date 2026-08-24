// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ReactiveCallbackRelayer} from "../src/ReactiveCallbackRelayer.sol";

contract DeployRelayer is Script {
    function run() external {
        address hookAddr = vm.envAddress("HOOK_ADDR");
        address systemProxy = vm.envAddress("DESTINATION_CALLBACK_PROXY_ADDR");

        vm.startBroadcast();
        ReactiveCallbackRelayer relayer = new ReactiveCallbackRelayer(hookAddr, systemProxy);
        vm.stopBroadcast();

        console.log("=== Relayer Deployment Complete ===");
        console.log("Relayer Address: ", address(relayer));
        console.log("Update .env with RELAYER_ADDR=", address(relayer));
    }
}
