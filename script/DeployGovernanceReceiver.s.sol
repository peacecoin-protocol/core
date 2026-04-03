// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { GovernanceReceiver } from "../src/governance/GovernanceReceiver.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title DeployGovernanceReceiver
 * @notice Deployment script for Polygon-side cross-chain governance infrastructure
 *
 * Deploys:
 * - TimelockController (1 day delay, GovernanceReceiver as proposer, anyone as executor)
 * - GovernanceReceiver (receives Wormhole messages, schedules on Timelock)
 *
 * Required environment variables:
 * - PRIVATE_KEY: Private key of the deployer
 *
 * Optional environment variables:
 * - WORMHOLE_RELAYER: Address of Wormhole Automatic Relayer on Polygon
 *   (defaults to WORMHOLE_RELAYER_POLYGON if unset)
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

    /// @notice Wormhole Automatic Relayer on Polygon mainnet
    address public constant WORMHOLE_RELAYER_POLYGON = 0x27428DD2d3DD32A4D7f7C497eAaa23130d894911;

    function run() external returns (address receiverAddr, address timelockAddr) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Allow overriding the Wormhole Relayer address for testing
        address wormholeRelayer = vm.envOr("WORMHOLE_RELAYER", WORMHOLE_RELAYER_POLYGON);

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy Polygon TimelockController
        // Empty proposers/executors — roles are granted explicitly below
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);

        TimelockController timelock = new TimelockController(
            TIMELOCK_DELAY, proposers, executors, deployer
        );
        timelockAddr = address(timelock);
        console.log("Polygon TimelockController deployed at:", timelockAddr);

        // Step 2: Deploy GovernanceReceiver
        GovernanceReceiver receiver = new GovernanceReceiver(
            wormholeRelayer, timelockAddr, deployer
        );
        receiverAddr = address(receiver);
        console.log("GovernanceReceiver deployed at:", receiverAddr);

        // Step 3: Grant PROPOSER_ROLE to GovernanceReceiver
        timelock.grantRole(timelock.PROPOSER_ROLE(), receiverAddr);

        // Step 4: Grant CANCELLER_ROLE to GovernanceReceiver (emergency cancellation)
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
        console.log("Wormhole Relayer:", wormholeRelayer);

        console.log("\n  NEXT STEPS:");
        console.log("1. Deploy GovernanceSender on Ethereum");
        console.log("2. Call receiver.setGovernanceSender(senderAddress) on Polygon");
        console.log("3. Call receiver.setEmergencyGuardian(multisigAddress) on Polygon");
        console.log("4. Transfer GovernanceReceiver ownership to Polygon Timelock");
        console.log("5. Transfer PCEToken ownership to Polygon Timelock (owner EOA tx)");
    }
}
