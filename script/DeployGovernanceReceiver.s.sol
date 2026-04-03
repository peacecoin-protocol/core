// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {GovernanceReceiver} from "../src/governance/GovernanceReceiver.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title DeployGovernanceReceiver
 * @notice Deployment script for Polygon-side cross-chain governance infrastructure (Executor Framework)
 *
 * Deploys:
 * - TimelockController (1 day delay, GovernanceReceiver as proposer, anyone as executor)
 * - GovernanceReceiver (receives Wormhole Executor VAAs, schedules on Timelock)
 *
 * Required environment variables:
 * - PRIVATE_KEY: Private key of the deployer
 *
 * Optional environment variables:
 * - CORE_BRIDGE: Wormhole Core Bridge address on Polygon
 *   (defaults to CORE_BRIDGE_POLYGON if unset)
 *
 * Post-deployment steps:
 * 1. Deploy GovernanceSender on Ethereum
 * 2. Call receiver.setGovernanceSender(senderAddress) on Polygon
 * 3. Call receiver.setEmergencyGuardian(multisigAddress) on Polygon
 *    (MUST be done BEFORE transferring ownership to Timelock)
 * 4. Transfer GovernanceReceiver ownership to Polygon Timelock
 * 5. Transfer PCEToken ownership to Polygon Timelock (owner EOA tx)
 *
 * Usage:
 * forge script script/DeployGovernanceReceiver.s.sol --rpc-url polygon --broadcast
 */
contract DeployGovernanceReceiver is Script {
    /// @notice Polygon Timelock delay: 1 day
    uint256 public constant TIMELOCK_DELAY = 1 days;

    /// @notice Wormhole Core Bridge on Polygon mainnet
    address public constant CORE_BRIDGE_POLYGON = 0x7A4B5a56256163F07b2C80A7cA55aBE66c4ec4d7;

    function run() external returns (address receiverAddr, address timelockAddr) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address coreBridge = vm.envOr("CORE_BRIDGE", CORE_BRIDGE_POLYGON);

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy Polygon TimelockController
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        TimelockController timelock = new TimelockController(
            TIMELOCK_DELAY, proposers, executors, deployer
        );
        timelockAddr = address(timelock);

        // Step 2: Deploy GovernanceReceiver
        GovernanceReceiver receiver = new GovernanceReceiver(coreBridge, timelockAddr, deployer);
        receiverAddr = address(receiver);

        // Step 3: Grant PROPOSER_ROLE to GovernanceReceiver
        timelock.grantRole(timelock.PROPOSER_ROLE(), receiverAddr);

        // Step 4: Grant CANCELLER_ROLE to GovernanceReceiver
        timelock.grantRole(timelock.CANCELLER_ROLE(), receiverAddr);

        // Step 5: Grant EXECUTOR_ROLE to address(0) — anyone can execute
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0));

        // Step 6: Renounce admin role
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopBroadcast();

        console.log("\nDeployment Summary:");
        console.log("===================");
        console.log("GovernanceReceiver:", receiverAddr);
        console.log("Polygon Timelock:", timelockAddr);
        console.log("Timelock Delay:", TIMELOCK_DELAY, "seconds");
        console.log("Wormhole Core Bridge:", coreBridge);

        console.log("\n  NEXT STEPS:");
        console.log("1. Deploy GovernanceSender on Ethereum");
        console.log("2. Call receiver.setGovernanceSender(senderAddress) on Polygon");
        console.log("3. Call receiver.setEmergencyGuardian(multisigAddress) on Polygon");
        console.log("4. Transfer GovernanceReceiver ownership to Polygon Timelock");
        console.log("5. Transfer PCEToken ownership to Polygon Timelock (owner EOA tx)");
    }
}
