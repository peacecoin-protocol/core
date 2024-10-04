// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.26 <0.9.0;

import { BaseScript } from "./Base.s.sol";

import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/tutorials/solidity-scripting
contract Upgrade is BaseScript {
    function run() public broadcast {
        address pceTokenAddress = 0x70e0bA845a1A0F2DA3359C97E0285013525FFC49;
        address pceCommunityTokenAddress = 0x95401dc811bb5740090279Ba06cfA8fcF6113778;

        Upgrades.upgradeProxy(pceTokenAddress, "PCETokenV2.sol:PCETokenV2", "");
        Upgrades.upgradeBeacon(pceCommunityTokenAddress, "PCECommunityTokenV2.sol:PCECommunityTokenV2");
    }
}
