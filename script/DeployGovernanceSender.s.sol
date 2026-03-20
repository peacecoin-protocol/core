// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { GovernanceSender } from "../src/governance/GovernanceSender.sol";

/**
 * @title DeployGovernanceSender
 * @notice Deployment script for Ethereum-side cross-chain governance infrastructure
 *
 * Deploys:
 * - GovernanceSender (sends governance proposals cross-chain via Wormhole)
 *
 * Required environment variables:
 * - GOVERNANCE_RECEIVER: Address of GovernanceReceiver on Polygon
 * - ETHEREUM_TIMELOCK: Address of Ethereum TimelockController (will become owner)
 * - PRIVATE_KEY: Private key of the deployer
 *
 * Optional environment variables:
 * - WORMHOLE_RELAYER: Address of Wormhole Relayer on Ethereum
 *   (defaults to WORMHOLE_RELAYER_ETHEREUM if unset)
 * - GAS_LIMIT: Gas limit for cross-chain delivery (defaults to 500_000)
 *
 * Post-deployment steps:
 * 1. Call receiver.setGovernanceSender(senderAddress) on Polygon
 * 2. Pre-fund GovernanceSender with ETH to cover Wormhole relayer fees
 *    (sendCrossChainGovernance pays from contract balance; fund with a buffer
 *    to absorb fee fluctuations between proposal creation and execution)
 * 3. Ownership is transferred to Ethereum Timelock at deployment
 *
 * Usage:
 * forge script script/DeployGovernanceSender.s.sol --rpc-url ethereum --broadcast
 */
contract DeployGovernanceSender is Script {
    /// @notice Gas limit for cross-chain delivery on Polygon
    uint256 public constant GAS_LIMIT = 500_000;

    /// @notice Wormhole Automatic Relayer on Ethereum mainnet
    address public constant WORMHOLE_RELAYER_ETHEREUM = 0x27428DD2d3DD32A4D7f7C497eAaa23130d894911;

    function run() external returns (address senderAddr) {
        address governanceReceiver = vm.envAddress("GOVERNANCE_RECEIVER");
        address ethereumTimelock = vm.envAddress("ETHEREUM_TIMELOCK");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Allow overriding the Wormhole Relayer address for testing
        address wormholeRelayer = vm.envOr("WORMHOLE_RELAYER", WORMHOLE_RELAYER_ETHEREUM);
        uint256 gasLimit = vm.envOr("GAS_LIMIT", GAS_LIMIT);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy GovernanceSender with Ethereum Timelock as owner
        GovernanceSender sender = new GovernanceSender(
            wormholeRelayer, governanceReceiver, gasLimit, ethereumTimelock
        );
        senderAddr = address(sender);

        vm.stopBroadcast();

        console.log("\nDeployment Summary:");
        console.log("===================");
        console.log("GovernanceSender:", senderAddr);
        console.log("Owner (Ethereum Timelock):", ethereumTimelock);
        console.log("Governance Receiver (Polygon):", governanceReceiver);
        console.log("Gas Limit:", gasLimit);
        console.log("Wormhole Relayer:", wormholeRelayer);

        console.log("\n  NEXT STEPS:");
        console.log("1. On Polygon: receiver.setGovernanceSender(", senderAddr, ")");
        console.log("2. Pre-fund GovernanceSender with ETH buffer for Wormhole relayer fees");
        console.log("3. Verify contract on Etherscan");
        console.log("4. Test with a governance proposal");
    }
}
