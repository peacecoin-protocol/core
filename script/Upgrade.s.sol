// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.26 <0.9.0;

import { BaseScript } from "./Base.s.sol";

import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { console2 } from "forge-std/console2.sol";


/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/tutorials/solidity-scripting
contract Upgrade is BaseScript {
    function run() public broadcast {
        address pceTokenAddress = 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9;
        address pceCommunityTokenAddress = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;

        Upgrades.upgradeProxy(pceTokenAddress, "PCETokenV4.sol:PCETokenV4", "");
        Upgrades.upgradeBeacon(pceCommunityTokenAddress, "PCECommunityTokenV3.sol:PCECommunityTokenV3");

        console2.log("PCETokenV3 upgraded");
        console2.log("PCECommunityTokenV3 upgraded");
    }
}
