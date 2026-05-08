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
/// NOTE: production proxy/beacon are owned by the Polygon Timelock; this script is only usable
/// when called from the Timelock (via governance proposal). For impl-only deploy used during
/// proposal preparation, use script/DeployImpl.s.sol.
///
/// Required environment variable:
/// - PRIVATE_KEY: deployer private key (must equal the Timelock for the upgrade calls to succeed)
contract Upgrade is Script {
    function run() external {
        address pceTokenAddress = 0xA4807a8C34353A5EA51aF073175950Cb6248dA7E;
        address pceCommunityTokenAddress = 0x6A73A610707C113F34D8B82498b6868e5f7FAA74;

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address pceTokenImpl = address(new PCEToken());
        address pceCommunityTokenImpl = address(new PCECommunityToken());

        UnsafeUpgrades.upgradeProxy(pceTokenAddress, pceTokenImpl, new bytes(0));
        UnsafeUpgrades.upgradeBeacon(pceCommunityTokenAddress, pceCommunityTokenImpl);

        vm.stopBroadcast();
    }
}
