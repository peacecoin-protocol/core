// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {GovernanceReceiver} from "../src/governance/GovernanceReceiver.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title DeployGovernanceReceiver
 * @notice Deploy GovernanceReceiver + Timelock on Polygon (Wormhole Core Bridge, no Relayer dependency)
 *
 * Required environment variables:
 * - PRIVATE_KEY: Private key of the deployer
 *
 * Optional environment variables:
 * - WORMHOLE_CORE: Wormhole Core Bridge address on Polygon
 *   (defaults to WORMHOLE_CORE_POLYGON if unset)
 *
 * Post-deployment steps:
 * 1. Deploy GovernanceSender on Ethereum
 * 2. Call receiver.setGovernanceSender(bytes32(uint256(uint160(senderAddr)))) on Polygon
 * 3. Call receiver.setEmergencyGuardian(multisigAddress) on Polygon
 *    (MUST be done BEFORE transferring ownership to Timelock)
 * 4. Transfer GovernanceReceiver ownership to Polygon Timelock
 * 5. Transfer PCEToken ownership to Polygon Timelock (owner EOA tx)
 *
 * Usage:
 * source .env && forge script script/DeployGovernanceReceiver.s.sol --rpc-url polygon --broadcast
 */
contract DeployGovernanceReceiver is Script {
    uint256 public constant TIMELOCK_DELAY = 1 days;

    /// @notice Wormhole Core Bridge on Polygon mainnet
    address public constant WORMHOLE_CORE_POLYGON = 0x7A4B5a56256163F07b2C80A7cA55aBE66c4ec4d7;

    function run() external returns (address receiverAddr, address timelockAddr) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address wormholeCore = vm.envOr("WORMHOLE_CORE", WORMHOLE_CORE_POLYGON);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Polygon TimelockController
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        TimelockController timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, deployer);
        timelockAddr = address(timelock);

        // Deploy GovernanceReceiver
        GovernanceReceiver receiver = new GovernanceReceiver(wormholeCore, timelockAddr, deployer);
        receiverAddr = address(receiver);

        // Grant roles
        timelock.grantRole(timelock.PROPOSER_ROLE(), receiverAddr);
        timelock.grantRole(timelock.CANCELLER_ROLE(), receiverAddr);
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopBroadcast();

        console.log("\nDeployment Summary:");
        console.log("===================");
        console.log("GovernanceReceiver:", receiverAddr);
        console.log("Polygon Timelock:", timelockAddr);
        console.log("Timelock Delay:", TIMELOCK_DELAY, "seconds");
        console.log("Wormhole Core Bridge:", wormholeCore);

        console.log("\nNEXT STEPS:");
        console.log("1. Deploy GovernanceSender on Ethereum");
        console.log("2. Call receiver.setGovernanceSender(bytes32(uint256(uint160(senderAddr)))) on Polygon");
        console.log("3. Call receiver.setEmergencyGuardian(multisigAddress) on Polygon");
        console.log("4. Transfer GovernanceReceiver ownership to Polygon Timelock");
        console.log("5. Transfer PCEToken ownership to Polygon Timelock (owner EOA tx)");
    }
}
