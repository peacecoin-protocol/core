// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.30 <0.9.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { PCEToken } from "../src/PCEToken.sol";
import { PCECommunityToken } from "../src/PCECommunityToken.sol";

/**
 * @title DeployImpl
 * @notice Deploy new implementation contracts for PCEToken and PCECommunityToken.
 *         Does NOT call upgradeTo/upgradeBeacon — the actual upgrade is executed via
 *         governance (Ethereum Governor → Wormhole → Polygon Timelock → upgradeToAndCall/upgradeTo).
 *
 * Storage layout validation should be performed beforehand via script/upgrade.sh with a dry-run.
 *
 * Required environment variables:
 * - PRIVATE_KEY: Private key of the deployer
 *
 * Usage:
 *   source .env && forge script script/DeployImpl.s.sol --rpc-url polygon --broadcast
 *
 * Output: new implementation addresses for use in governance proposal calldata.
 */
contract DeployImpl is Script {
    function run() external returns (address pceTokenImpl, address pceCommunityTokenImpl) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        PCEToken pceToken = new PCEToken();
        pceTokenImpl = address(pceToken);

        PCECommunityToken pceCommunityToken = new PCECommunityToken();
        pceCommunityTokenImpl = address(pceCommunityToken);

        vm.stopBroadcast();

        console.log("\n=== New Implementation Contracts ===");
        console.log("PCEToken implementation:", pceTokenImpl);
        console.log("PCECommunityToken implementation:", pceCommunityTokenImpl);
        console.log("");
        console.log("Versions:");
        console.log("  PCEToken:", PCEToken(pceTokenImpl).version());
        console.log("  PCECommunityToken:", PCECommunityToken(pceCommunityTokenImpl).version());
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Verify contracts on Polygonscan");
        console.log("2. Create Tally proposal with two actions:");
        console.log("   a) Target: PCEToken proxy (0xA4807a8C34353A5EA51aF073175950Cb6248dA7E)");
        console.log("      Method: upgradeToAndCall(address,bytes)");
        console.log("      Args: (pceTokenImpl, 0x)");
        console.log("   b) Target: PCECommunityToken beacon (0x6A73A610707C113F34D8B82498b6868e5f7FAA74)");
        console.log("      Method: upgradeTo(address)");
        console.log("      Args: (pceCommunityTokenImpl)");
    }
}
