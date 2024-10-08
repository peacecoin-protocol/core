// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "../PCECommunityTokenV2.sol";

contract PCECommunityScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        PCECommunityTokenV2 comminity = new PCECommunityTokenV2();
        vm.stopBroadcast();
    }
}
