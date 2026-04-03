// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {GovernanceReceiver} from "../src/governance/GovernanceReceiver.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title DeployGovTestPolygon
 * @notice Deploy test GovernanceReceiver + Timelock on Polygon for E2E testing
 *
 * Usage:
 * source .env && forge script script/DeployGovTestPolygon.s.sol --rpc-url polygon --broadcast
 */
contract DeployGovTestPolygon is Script {
    address public constant WORMHOLE_CORE_POLYGON = 0x7A4B5a56256163F07b2C80A7cA55aBE66c4ec4d7;
    uint256 public constant TIMELOCK_DELAY = 60;

    function run() external returns (address receiverAddr, address timelockAddr) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        TimelockController timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, deployer);
        timelockAddr = address(timelock);

        GovernanceReceiver receiver = new GovernanceReceiver(WORMHOLE_CORE_POLYGON, timelockAddr, deployer);
        receiverAddr = address(receiver);

        timelock.grantRole(timelock.PROPOSER_ROLE(), receiverAddr);
        timelock.grantRole(timelock.CANCELLER_ROLE(), receiverAddr);
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopBroadcast();

        console.log("\n=== GovTest Polygon Deployed ===");
        console.log("TestGovernanceReceiver:", receiverAddr);
        console.log("TestPolygonTimelock (60s):", timelockAddr);
        console.log("Wormhole Core Bridge:", WORMHOLE_CORE_POLYGON);
    }
}
