// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.30 <0.9.0;

import { Script } from "forge-std/Script.sol";
import { PCEToken } from "../src/PCEToken.sol";
import { PCECommunityToken } from "../src/PCECommunityToken.sol";
import { UnsafeUpgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @dev Storage layout validation is performed by script/upgrade.sh before this script runs.
/// PCECommunityToken links external libraries (VoucherSystem / TokenValueOps / ArigatoCreation),
/// which OZ's name-based Upgrades.upgrade*("Contract.sol:Name", opts) cannot deploy via vm.getCode.
/// Deploy implementations directly via `new` (forge auto-handles library linking + CREATE2),
/// then upgrade via the address-based variants of UnsafeUpgrades.
///
/// Required environment variable:
/// - PRIVATE_KEY: deployer private key (must own the DEV proxy / beacon)
contract UpgradeDEV is Script {
    function run() external {
        address pceTokenAddress = 0x62Ef93EAa5bB3E47E0e855C323ef156c8E3D8913;
        address pceCommunityTokenAddress = 0xA9D965660dcF0fA73E709fd802e9DEF2d9b52952;

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address pceTokenImpl = address(new PCEToken());
        address pceCommunityTokenImpl = address(new PCECommunityToken());

        UnsafeUpgrades.upgradeProxy(pceTokenAddress, pceTokenImpl, new bytes(0));
        UnsafeUpgrades.upgradeBeacon(pceCommunityTokenAddress, pceCommunityTokenImpl);

        vm.stopBroadcast();
    }
}
