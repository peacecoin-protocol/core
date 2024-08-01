// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.26 <0.9.0;

import { BaseScript } from "./Base.s.sol";

import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/tutorials/solidity-scripting
contract Upgrade is BaseScript {
    function run() public broadcast {
        address pceTokenAddress = 0x3Aa5ebB10DC797CAC828524e59A333d0A371443c;

        Upgrades.upgradeProxy(pceTokenAddress, "PCETokenV2.sol:PCETokenV2", "");
    }
}
