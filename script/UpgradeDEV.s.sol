// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.26 <0.9.0;

import { BaseScript } from "./Base.s.sol";

import { Upgrades, Options } from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/tutorials/solidity-scripting
/// Storage layout validation is performed by script/upgrade.sh before this script runs.
contract UpgradeDEV is BaseScript {
    function run() public broadcast {
        address pceTokenAddress = 0x62Ef93EAa5bB3E47E0e855C323ef156c8E3D8913;
        address pceCommunityTokenAddress = 0xA9D965660dcF0fA73E709fd802e9DEF2d9b52952;

        Options memory opts;
        opts.unsafeSkipStorageCheck = true;

        Upgrades.upgradeProxy(pceTokenAddress, "PCEToken.sol:PCEToken", "", opts);
        Upgrades.upgradeBeacon(pceCommunityTokenAddress, "PCECommunityToken.sol:PCECommunityToken", opts);
    }
}
