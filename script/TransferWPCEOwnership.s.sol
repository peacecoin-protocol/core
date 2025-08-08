// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { WrappedPCEToken } from "../src/WrappedPCEToken.sol";

/**
 * @title TransferWPCEOwnership
 * @notice Script to transfer WPCE token ownership to Timelock
 *
 * This script transfers ownership of the WPCE token contract to the Timelock,
 * ensuring that only governance proposals can make changes to the token.
 *
 * Required environment variables:
 * - WPCE_TOKEN_ADDRESS: Address of WPCE token
 * - TIMELOCK_ADDRESS: Address of deployed Timelock
 * - PRIVATE_KEY: Private key of current owner
 */
contract TransferWPCEOwnership is Script {
    function run() external {
        address wpceToken = vm.envAddress("WPCE_TOKEN_ADDRESS");
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");
        uint256 ownerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(ownerPrivateKey);

        WrappedPCEToken wpce = WrappedPCEToken(wpceToken);

        console.log("Starting WPCE ownership transfer...");
        console.log("Current owner:", wpce.owner());
        console.log("New owner (Timelock):", timelock);

        // Check current ownership
        if (wpce.owner() != timelock) {
            // Transfer ownership to Timelock
            wpce.transferOwnership(timelock);
            console.log("\nOwnership transferred successfully!");

            // Note: The new owner must accept ownership in a separate transaction
            console.log("\nIMPORTANT: Timelock must accept ownership by calling acceptOwnership()");
            console.log("This can be done through a governance proposal.");
        } else {
            console.log("\nWPCE is already owned by Timelock");
        }

        vm.stopBroadcast();

        console.log("\nWPCE Ownership Transfer Complete!");
        console.log("===================================");
        console.log("WPCE token now controlled by Timelock");
        console.log("Only governance proposals can make changes");
    }
}
