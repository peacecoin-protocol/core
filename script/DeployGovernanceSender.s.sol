// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {GovernanceSender} from "../src/governance/GovernanceSender.sol";
import {toUniversalAddress} from "wormhole-solidity-sdk/Utils.sol";

/**
 * @title DeployGovernanceSender
 * @notice Deployment script for Ethereum-side cross-chain governance (Executor Framework)
 *
 * Deploys:
 * - GovernanceSender (sends governance proposals cross-chain via Wormhole Executor)
 *
 * Required environment variables:
 * - GOVERNANCE_RECEIVER: Address of GovernanceReceiver on Polygon
 * - ETHEREUM_TIMELOCK: Address of Ethereum TimelockController (will become owner)
 * - PRIVATE_KEY: Private key of the deployer
 *
 * Optional environment variables:
 * - CORE_BRIDGE: Wormhole Core Bridge address on Ethereum
 *   (defaults to CORE_BRIDGE_ETHEREUM if unset)
 * - EXECUTOR_QUOTER_ROUTER: Address of ExecutorQuoterRouter on Ethereum
 *   (defaults to EXECUTOR_QUOTER_ROUTER_ETHEREUM if unset)
 * - QUOTER_ADDRESS: Address of on-chain quoter
 *   (defaults to QUOTER_ADDRESS_DEFAULT if unset)
 * - GAS_LIMIT: Gas limit for cross-chain delivery (defaults to 500_000)
 *
 * Post-deployment steps:
 * 1. Call receiver.setGovernanceSender(senderAddress) on Polygon
 * 2. Pre-fund GovernanceSender with ETH buffer for Wormhole Executor fees
 * 3. Verify contract on Etherscan
 * 4. Test with a governance proposal
 *
 * Usage:
 * forge script script/DeployGovernanceSender.s.sol --rpc-url ethereum --broadcast
 */
contract DeployGovernanceSender is Script {
    /// @notice Gas limit for cross-chain delivery on Polygon
    uint128 public constant GAS_LIMIT = 500_000;

    /// @notice Wormhole Core Bridge on Ethereum mainnet
    address public constant CORE_BRIDGE_ETHEREUM = 0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B;

    /// @notice ExecutorQuoterRouter on Ethereum mainnet
    address public constant EXECUTOR_QUOTER_ROUTER_ETHEREUM = 0xF22F1c0A3a8Cb42F695601731974784C499C4EF3;

    /// @notice Default on-chain quoter (Wormhole Labs)
    address public constant QUOTER_ADDRESS_DEFAULT = 0xA25862D222Eb8343505c12d96e097e4332468D60;

    function run() external returns (address senderAddr) {
        address governanceReceiver = vm.envAddress("GOVERNANCE_RECEIVER");
        address ethereumTimelock = vm.envAddress("ETHEREUM_TIMELOCK");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address coreBridge = vm.envOr("CORE_BRIDGE", CORE_BRIDGE_ETHEREUM);
        address executorQuoterRouter = vm.envOr("EXECUTOR_QUOTER_ROUTER", EXECUTOR_QUOTER_ROUTER_ETHEREUM);
        address quoterAddress = vm.envOr("QUOTER_ADDRESS", QUOTER_ADDRESS_DEFAULT);
        uint256 gasLimitRaw = vm.envOr("GAS_LIMIT", uint256(GAS_LIMIT));
        require(gasLimitRaw <= type(uint128).max, "GAS_LIMIT exceeds uint128 max");
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 gasLimitVal = uint128(gasLimitRaw);

        bytes32 receiverBytes32 = toUniversalAddress(governanceReceiver);

        vm.startBroadcast(deployerPrivateKey);

        GovernanceSender sender = new GovernanceSender(
            coreBridge, executorQuoterRouter, receiverBytes32, gasLimitVal, quoterAddress, ethereumTimelock
        );
        senderAddr = address(sender);

        vm.stopBroadcast();

        console.log("\nDeployment Summary:");
        console.log("===================");
        console.log("GovernanceSender:", senderAddr);
        console.log("Owner (Ethereum Timelock):", ethereumTimelock);
        console.log("Governance Receiver (Polygon):", governanceReceiver);
        console.log("Gas Limit:", uint256(gasLimitVal));
        console.log("Core Bridge:", coreBridge);
        console.log("ExecutorQuoterRouter:", executorQuoterRouter);
        console.log("Quoter:", quoterAddress);

        console.log("\n  NEXT STEPS:");
        console.log("1. On Polygon: receiver.setGovernanceSender(toUniversalAddress(", senderAddr, "))");
        console.log("2. Pre-fund GovernanceSender with ETH buffer for Wormhole Executor fees");
        console.log("3. Verify contract on Etherscan");
        console.log("4. Test with a governance proposal");
    }
}
