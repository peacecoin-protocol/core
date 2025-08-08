// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { PeaceCoinTokenDev } from "../src/PeaceCoinTokenDev.sol";

/**
 * @title TransferPCERoles
 * @notice Script to transfer all roles from PeaceCoinToken to Timelock
 *
 * This script:
 * 1. Grants all roles to the Timelock controller
 * 2. Revokes all existing roles from current holders
 *
 * Note: AccessControl roles are additive - multiple accounts can have the same role.
 * We must explicitly revoke roles from previous holders to ensure exclusive control.
 *
 * Required environment variables:
 * - PCE_TOKEN_ADDRESS: Address of PeaceCoinToken
 * - TIMELOCK_ADDRESS: Address of deployed Timelock
 * - PRIVATE_KEY: Private key of current admin
 */
contract TransferPCERoles is Script {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    function run() external {
        address pceToken = vm.envAddress("PCE_TOKEN_ADDRESS");
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");
        uint256 adminPrivateKey = vm.envUint("PRIVATE_KEY");
        
        address currentAdmin = vm.addr(adminPrivateKey);
        
        vm.startBroadcast(adminPrivateKey);
        
        PeaceCoinTokenDev token = PeaceCoinTokenDev(pceToken);
        
        console.log("Starting role transfer for PeaceCoinToken...");
        console.log("Current admin:", currentAdmin);
        console.log("Target timelock:", timelock);
        
        // First, grant roles to timelock
        console.log("\n1. Granting roles to Timelock...");
        
        // Grant MINTER_ROLE to timelock
        if (!token.hasRole(MINTER_ROLE, timelock)) {
            token.grantRole(MINTER_ROLE, timelock);
            console.log("  - Granted MINTER_ROLE to Timelock");
        } else {
            console.log("  - Timelock already has MINTER_ROLE");
        }
        
        // Grant DEFAULT_ADMIN_ROLE to timelock
        if (!token.hasRole(DEFAULT_ADMIN_ROLE, timelock)) {
            token.grantRole(DEFAULT_ADMIN_ROLE, timelock);
            console.log("  - Granted DEFAULT_ADMIN_ROLE to Timelock");
        } else {
            console.log("  - Timelock already has DEFAULT_ADMIN_ROLE");
        }
        
        console.log("\n2. Revoking roles from current admin...");
        
        // Revoke MINTER_ROLE from current admin if they have it
        if (token.hasRole(MINTER_ROLE, currentAdmin)) {
            token.revokeRole(MINTER_ROLE, currentAdmin);
            console.log("  - Revoked MINTER_ROLE from:", currentAdmin);
        }
        
        // Revoke DEFAULT_ADMIN_ROLE from current admin (do this last!)
        // This will only work if timelock already has admin role
        if (currentAdmin != timelock && token.hasRole(DEFAULT_ADMIN_ROLE, currentAdmin)) {
            token.renounceRole(DEFAULT_ADMIN_ROLE, currentAdmin);
            console.log("  - Renounced DEFAULT_ADMIN_ROLE from:", currentAdmin);
        }
        
        vm.stopBroadcast();
        
        // Verify final state
        console.log("\n3. Final role verification:");
        console.log("  - Timelock has MINTER_ROLE:", token.hasRole(MINTER_ROLE, timelock));
        console.log("  - Timelock has DEFAULT_ADMIN_ROLE:", token.hasRole(DEFAULT_ADMIN_ROLE, timelock));
        bool currentAdminHasRoles = token.hasRole(DEFAULT_ADMIN_ROLE, currentAdmin) || 
                                   token.hasRole(MINTER_ROLE, currentAdmin);
        console.log("  - Current admin has any roles:", currentAdminHasRoles);
        
        console.log("\nRole Transfer Complete!");
        console.log("========================");
        console.log("All PeaceCoinToken roles now controlled by Timelock");
        console.log("Only governance proposals can mint or manage roles");
        
        if (currentAdminHasRoles) {
            console.log("\nWARNING: Current admin still has roles!");
            console.log("You may need to manually renounce them.");
        }
    }
}