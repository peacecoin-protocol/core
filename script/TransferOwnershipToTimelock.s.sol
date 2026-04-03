// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TransferOwnershipToTimelock
 * @notice PIP-14 implementation: Transfer PCEToken and CommunityToken beacon
 *         ownership from EOA to Polygon TimelockController.
 *
 * This is an irreversible operation. After execution, all onlyOwner functions
 * (mint, parameter changes, upgrades) require governance approval via:
 *   Ethereum Governor → Wormhole → Polygon Timelock
 *
 * Required environment variables:
 * - POLYGON_TIMELOCK: Address of the Polygon TimelockController
 * - PRIVATE_KEY: Private key of the current EOA owner
 *
 * Optional environment variables:
 * - PCE_TOKEN: PCEToken proxy address (defaults to DEV)
 * - BEACON: PCECommunityToken beacon address (defaults to DEV)
 *
 * Usage:
 * forge script script/TransferOwnershipToTimelock.s.sol \
 *   --rpc-url polygon --broadcast --interactives 1
 */
contract TransferOwnershipToTimelock is Script {
    // DEV environment addresses (Polygon mainnet)
    address public constant PCE_TOKEN_DEV = 0x62Ef93EAa5bB3E47E0e855C323ef156c8E3D8913;
    address public constant BEACON_DEV = 0xA9D965660dcF0fA73E709fd802e9DEF2d9b52952;

    function run() external {
        address polygonTimelock = vm.envAddress("POLYGON_TIMELOCK");
        uint256 ownerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(ownerPrivateKey);

        address pceToken = vm.envOr("PCE_TOKEN", PCE_TOKEN_DEV);
        address beacon = vm.envOr("BEACON", BEACON_DEV);

        // Pre-flight checks
        address currentPceOwner = OwnableUpgradeable(pceToken).owner();
        address currentBeaconOwner = Ownable(beacon).owner();

        require(polygonTimelock != address(0), "Invalid timelock address");
        require(polygonTimelock != owner, "Timelock is already the owner");

        bool pceNeedsTransfer = currentPceOwner == owner;
        bool beaconNeedsTransfer = currentBeaconOwner == owner;

        // At least one contract must need transfer
        require(pceNeedsTransfer || beaconNeedsTransfer, "Both already transferred");

        // If one is already transferred, it must be to the correct timelock
        if (!pceNeedsTransfer) {
            require(currentPceOwner == polygonTimelock, "PCEToken owned by unexpected address");
        }
        if (!beaconNeedsTransfer) {
            require(currentBeaconOwner == polygonTimelock, "Beacon owned by unexpected address");
        }

        console.log("=== PIP-14: Transfer Ownership to Timelock ===");
        console.log("");
        console.log("Current owner (EOA):", owner);
        console.log("New owner (Timelock):", polygonTimelock);
        console.log("");
        console.log("PCEToken proxy:", pceToken);
        console.log("  current owner:", currentPceOwner);
        console.log("  needs transfer:", pceNeedsTransfer ? "YES" : "NO (already done)");
        console.log("CommunityToken beacon:", beacon);
        console.log("  current owner:", currentBeaconOwner);
        console.log("  needs transfer:", beaconNeedsTransfer ? "YES" : "NO (already done)");
        console.log("");
        console.log("WARNING: This operation is IRREVERSIBLE.");
        console.log("After execution, all onlyOwner functions require governance approval.");

        vm.startBroadcast(ownerPrivateKey);

        // Step 1: Transfer PCEToken ownership (skip if already done)
        if (pceNeedsTransfer) {
            OwnableUpgradeable(pceToken).transferOwnership(polygonTimelock);
            console.log("");
            console.log("[OK] PCEToken ownership transferred to:", polygonTimelock);
        } else {
            console.log("");
            console.log("[SKIP] PCEToken ownership already transferred");
        }

        // Step 2: Transfer Beacon ownership (skip if already done)
        if (beaconNeedsTransfer) {
            Ownable(beacon).transferOwnership(polygonTimelock);
            console.log("[OK] Beacon ownership transferred to:", polygonTimelock);
        } else {
            console.log("[SKIP] Beacon ownership already transferred");
        }

        vm.stopBroadcast();

        // Post-flight verification
        address newPceOwner = OwnableUpgradeable(pceToken).owner();
        address newBeaconOwner = Ownable(beacon).owner();

        require(newPceOwner == polygonTimelock, "PCEToken transfer failed");
        require(newBeaconOwner == polygonTimelock, "Beacon transfer failed");

        console.log("");
        console.log("=== Verification ===");
        console.log("PCEToken new owner:", newPceOwner);
        console.log("Beacon new owner:", newBeaconOwner);
        console.log("");
        console.log("PIP-14 ownership transfer complete.");
    }
}
