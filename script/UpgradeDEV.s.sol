// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.26 <0.9.0;

import { BaseScript } from "./Base.s.sol";

import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/tutorials/solidity-scripting
contract UpgradeDEV is BaseScript {
    function run() public broadcast {
        address pceTokenAddress = 0x62Ef93EAa5bB3E47E0e855C323ef156c8E3D8913;
        address pceCommunityTokenAddress = 0xA9D965660dcF0fA73E709fd802e9DEF2d9b52952;

        Upgrades.upgradeProxy(pceTokenAddress, "PCETokenV3.sol:PCETokenV3", "");
        Upgrades.upgradeBeacon(pceCommunityTokenAddress, "PCECommunityTokenV3.sol:PCECommunityTokenV3");
    }
}
