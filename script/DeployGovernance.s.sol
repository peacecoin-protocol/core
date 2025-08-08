// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { PCEGovernor } from "../src/PCEGovernor.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployGovernance
 * @notice Deployment script for PCE Governor and Timelock
 *
 * Required environment variables:
 * - WPCE_TOKEN_ADDRESS: Address of the WPCE token
 * - PRIVATE_KEY: Private key of the deployer
 *
 * Usage:
 * forge script script/DeployGovernance.s.sol --rpc-url <RPC_URL> --broadcast
 */
contract DeployGovernance is Script {
    // Governance parameters
    uint256 constant TIMELOCK_DELAY = 2 days;        // 2 days in seconds for timelock
    uint256 constant VOTING_DELAY = 1;            // ~1 block (12s per block)
    uint256 constant VOTING_PERIOD = 7200 * 7;          // ~7 days in blocks (12s per block)
    uint256 constant PROPOSAL_THRESHOLD = 1000e18;   // 1000 WPCE to create proposal
    uint256 constant QUORUM_PERCENTAGE = 4;          // 4% of total supply

    function run() external returns (
        address governor,
        address governorImplementation,
        address timelock
    ) {
        address wpceToken = vm.envAddress("WPCE_TOKEN_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy Timelock Controller
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = address(0); // Will be set to governor later
        executors[0] = address(0); // Anyone can execute

        timelock = address(new TimelockController(
            TIMELOCK_DELAY,
            proposers,
            executors,
            deployer // Initial admin, will renounce after setup
        ));
        console.log("TimelockController deployed at:", timelock);

        // Step 2: Deploy Governor implementation
        governorImplementation = address(new PCEGovernor());
        console.log("PCEGovernor implementation deployed at:", governorImplementation);

        // Step 3: Deploy Governor proxy and initialize
        bytes memory initData = abi.encodeWithSelector(
            PCEGovernor.initialize.selector,
            "PCE Governor",
            wpceToken,
            timelock,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            QUORUM_PERCENTAGE
        );

        governor = address(new ERC1967Proxy(governorImplementation, initData));
        console.log("PCEGovernor deployed at:", governor);

        // Step 4: Configure Timelock roles
        // Grant proposer role to governor
        TimelockController timelockContract = TimelockController(payable(timelock));
        timelockContract.grantRole(timelockContract.PROPOSER_ROLE(), governor);

        // Grant executor role to address(0) = anyone can execute
        timelockContract.grantRole(timelockContract.EXECUTOR_ROLE(), address(0));

        // Renounce admin role (only timelock can manage itself now)
        timelockContract.renounceRole(timelockContract.DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopBroadcast();

        // Verify deployment
        PCEGovernor governorContract = PCEGovernor(payable(governor));

        console.log("\nDeployment Summary:");
        console.log("===================");
        console.log("Governor:", governor);
        console.log("Governor Implementation:", governorImplementation);
        console.log("Timelock:", timelock);
        console.log("\nGovernance Parameters:");
        console.log("  Name:", governorContract.name());
        console.log("  Voting Delay:", governorContract.votingDelay(), "blocks");
        console.log("  Voting Period:", governorContract.votingPeriod(), "blocks");
        console.log("  Proposal Threshold:", governorContract.proposalThreshold(), "wei");
        console.log("  Quorum:", governorContract.quorumNumerator(), "%");

        console.log("\n  IMPORTANT NEXT STEPS:");
        console.log("Note: Governor upgrades are already controlled by Timelock (UUPS pattern)");
        console.log("");
        console.log("1. Run TransferWPCEOwnership script to transfer WPCE ownership to Timelock");
        console.log("2. Run TransferPCERoles script to transfer PCE roles to Timelock");
        console.log("3. Verify contracts on Etherscan");
        console.log("4. Create and test first governance proposal");
    }
}
