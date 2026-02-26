// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.26 <0.9.0;

import { PCEToken } from "../src/PCEToken.sol";

import { BaseScript } from "./Base.s.sol";

import { console2 } from "forge-std/console2.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/tutorials/solidity-scripting
contract DeployDEV is BaseScript {
    function run() public broadcast returns (address, address) {
        address pceCommunityTokenAddress = Upgrades.deployBeacon("PCECommunityToken.sol:PCECommunityToken", broadcaster);

        address pceTokenAddress = Upgrades.deployUUPSProxy(
            "PCEToken.sol:PCEToken",
            abi.encodeCall(PCEToken.initialize, ())
        );

        // Post-deploy configuration
        PCEToken pceToken = PCEToken(pceTokenAddress);
        pceToken.setCommunityTokenAddress(pceCommunityTokenAddress);

        console2.log("PCE Community Token deployed at", pceCommunityTokenAddress);
        console2.log("PCE Token deployed at", pceTokenAddress);

        return (pceCommunityTokenAddress, pceTokenAddress);
    }
}
