// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "../PCETokenV3.sol";
import "../PCECommunityTokenV2.sol";

contract PCEScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        PCECommunityTokenV2 communityToken = new PCECommunityTokenV2();
        PCETokenV3 pceToken = new PCETokenV3();
        pceToken.initialize("PCE Coin", "PCE", address(communityToken),address(0));

        vm.stopBroadcast();
    }
}
