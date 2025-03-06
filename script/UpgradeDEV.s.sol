// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.26 <0.9.0;

import { BaseScript } from "./Base.s.sol";

import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/tutorials/solidity-scripting
contract UpgradeDEV is BaseScript {
    function run() public broadcast {
        address pceTokenAddress = 0x281C4F2a7c3dF3e15DD325FD9C7477B0c4a3F0FC;
        address pceCommunityTokenAddress = 0x44Bbd400Cb0a39C80bF10256101CD588c891E272;

        Upgrades.upgradeProxy(pceTokenAddress, "PCETokenV2.sol:PCETokenV2", "");
        Upgrades.upgradeBeacon(pceCommunityTokenAddress, "PCECommunityTokenV2.sol:PCECommunityTokenV2");
    }
}
