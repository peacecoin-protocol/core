// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {GovernanceSender} from "../src/governance/GovernanceSender.sol";

/**
 * @title DeployGovernanceSender
 * @notice Deploy GovernanceSender on Ethereum (Wormhole Core Bridge, no Relayer dependency)
 *
 * Required environment variables:
 * - GOVERNANCE_RECEIVER: Address of GovernanceReceiver on Polygon
 * - ETHEREUM_TIMELOCK: Address of Ethereum TimelockController (will become owner)
 * - PRIVATE_KEY: Private key of the deployer
 *
 * Optional environment variables:
 * - WORMHOLE_CORE: Wormhole Core Bridge address on Ethereum
 *   (defaults to WORMHOLE_CORE_ETHEREUM if unset)
 *
 * Post-deployment steps:
 * 1. On Polygon: receiver.setGovernanceSender(bytes32(uint256(uint160(senderAddr))))
 * 2. Pre-fund GovernanceSender with ETH for Wormhole message fees
 * 3. Verify contract on Etherscan
 * 4. Test with a governance proposal
 *
 * Usage:
 * source .env && forge script script/DeployGovernanceSender.s.sol --rpc-url mainnet --broadcast
 */
contract DeployGovernanceSender is Script {
    /// @notice Wormhole Core Bridge on Ethereum mainnet
    address public constant WORMHOLE_CORE_ETHEREUM = 0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B;

    function run() external returns (address senderAddr) {
        address governanceReceiver = vm.envAddress("GOVERNANCE_RECEIVER");
        address ethereumTimelock = vm.envAddress("ETHEREUM_TIMELOCK");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address wormholeCore = vm.envOr("WORMHOLE_CORE", WORMHOLE_CORE_ETHEREUM);

        vm.startBroadcast(deployerPrivateKey);

        GovernanceSender sender = new GovernanceSender(wormholeCore, governanceReceiver, ethereumTimelock);
        senderAddr = address(sender);

        vm.stopBroadcast();

        console.log("\nDeployment Summary:");
        console.log("===================");
        console.log("GovernanceSender:", senderAddr);
        console.log("Owner (Ethereum Timelock):", ethereumTimelock);
        console.log("Governance Receiver (Polygon):", governanceReceiver);
        console.log("Wormhole Core Bridge:", wormholeCore);

        console.log("\nNEXT STEPS:");
        console.log("1. On Polygon: receiver.setGovernanceSender(bytes32(uint256(uint160(senderAddr))))");
        console.log("2. Pre-fund GovernanceSender with ETH for Wormhole message fees");
        console.log("3. Verify contract on Etherscan");
        console.log("4. Test with a governance proposal");
    }
}
