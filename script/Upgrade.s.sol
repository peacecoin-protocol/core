// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.26 <0.9.0;

import { BaseScript } from "./Base.s.sol";

import { Upgrades, Options } from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/tutorials/solidity-scripting
/// Storage layout validation is performed by script/upgrade.sh before this script runs.
contract Upgrade is BaseScript {
    function run() public broadcast {
        address pceTokenAddress = 0xA4807a8C34353A5EA51aF073175950Cb6248dA7E;
        address pceCommunityTokenAddress = 0x6A73A610707C113F34D8B82498b6868e5f7FAA74;

        Options memory opts;
        opts.unsafeSkipStorageCheck = true;

        Upgrades.upgradeProxy(pceTokenAddress, "PCEToken.sol:PCEToken", "", opts);
        Upgrades.upgradeBeacon(pceCommunityTokenAddress, "PCECommunityToken.sol:PCECommunityToken", opts);
    }
}
