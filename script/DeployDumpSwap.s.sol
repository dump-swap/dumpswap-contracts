// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/DumpSwap.sol";

contract DeployDumpSwap is Script {
    function run() external {
        vm.startBroadcast();

        DumpSwap dumpSwap = new DumpSwap(address(0));
        console.log("DumpSwap deployed at:", address(dumpSwap));

        vm.stopBroadcast();
    }
}
