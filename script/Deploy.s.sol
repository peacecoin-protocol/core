// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.26 <0.9.0;

import { PCEToken } from "../src/PCEToken.sol";
import { PCECommunityToken } from "../src/PCECommunityToken.sol";

import { BaseScript } from "./Base.s.sol";

import { console2 } from "forge-std/console2.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/tutorials/solidity-scripting
contract Deploy is BaseScript {
    function run() public broadcast returns (address, address) {
        address pceCommunityTokenAddress = Upgrades.deployBeacon("PCECommunityToken.sol:PCECommunityToken", broadcaster);

        // mainnet: https://github.com/maticnetwork/static/blob/master/network/mainnet/v1/index.json
        // 0xa40fc0782bee28dd2cf8cb4ac2ecdb05c537f1b5
        // amoy: https://github.com/maticnetwork/static/blob/master/network/testnet/amoy/index.json
        // 0x687C1D2dd0F422421BeF7aC2a52f50e858CAA867
        address pceTokenAddress = Upgrades.deployUUPSProxy(
            "PCEToken.sol:PCEToken",
            abi.encodeCall(
                PCEToken.initialize,
                ("PCE Token", "PCE", pceCommunityTokenAddress, 0x687C1D2dd0F422421BeF7aC2a52f50e858CAA867)
            )
        );

        console2.log("PCE Community Token deployed at", pceCommunityTokenAddress);
        console2.log("PCE Token deployed at", pceTokenAddress);

        return (pceCommunityTokenAddress, pceTokenAddress);
    }
}
