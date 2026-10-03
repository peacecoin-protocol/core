// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { PCEGovernor } from "../src/PCEGovernor.sol";
import { LegacyPercentageGovernor } from "./fixtures/LegacyPercentageGovernor.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

contract FixedVotingPower {
    function clock() external view returns (uint48) {
        return uint48(block.number);
    }

    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=blocknumber&from=default";
    }

    function getPastVotes(address, uint256) external pure returns (uint256) {
        return 1_000_000 ether;
    }

    function getPastTotalSupply(uint256) external pure returns (uint256) {
        return 1_000_000 ether;
    }
}

contract GovernorUpgradeTest is Test {
    address internal TOKEN;
    address internal timelock;
    LegacyPercentageGovernor internal legacy;
    address internal newImplementation;

    function setUp() public {
        TOKEN = address(new FixedVotingPower());
        timelock = address(new TimelockController(1 days, new address[](0), new address[](0), address(this)));
        address impl = deployCode("LegacyPercentageGovernor.sol:LegacyPercentageGovernor");
        legacy = LegacyPercentageGovernor(
            payable(
                address(
                    new ERC1967Proxy(
                        impl,
                        abi.encodeCall(
                            LegacyPercentageGovernor.initialize,
                            ("PCE Governor", TOKEN, timelock, 12, 30, 1000 ether, 4)
                        )
                    )
                )
            )
        );
        newImplementation = deployCode("PCEGovernor.sol:PCEGovernor");
    }

    function _migration(address token, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeCall(PCEGovernor.initializeAbsoluteQuorum, (token, amount));
    }

    function testAtomicUpgradePreservesConfigurationAndSetsQuorum() public {
        vm.prank(timelock);
        legacy.upgradeToAndCall(newImplementation, _migration(TOKEN, 500_000 ether));
        PCEGovernor upgraded = PCEGovernor(payable(address(legacy)));
        assertEq(upgraded.name(), "PCE Governor");
        assertEq(upgraded.votingDelay(), 12);
        assertEq(upgraded.votingPeriod(), 30);
        assertEq(upgraded.proposalThreshold(), 1000 ether);
        assertEq(upgraded.timelock(), timelock);
        assertEq(address(upgraded.token()), TOKEN);
        assertEq(upgraded.quorum(0), 500_000 ether);
    }

    function testLegacyUpgradeWithoutMigrationFailsClosed() public {
        vm.prank(timelock);
        legacy.upgradeToAndCall(newImplementation, "");
        vm.expectRevert("Absolute quorum not configured");
        PCEGovernor(payable(address(legacy))).quorum(0);
    }

    function testInvalidQuorumMigrationRollsBackUpgrade() public {
        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        bytes32 beforeImpl = vm.load(address(legacy), implSlot);
        vm.prank(timelock);
        vm.expectRevert("Invalid absolute quorum");
        legacy.upgradeToAndCall(newImplementation, _migration(TOKEN, 0));
        assertEq(vm.load(address(legacy), implSlot), beforeImpl);
        assertEq(legacy.timelock(), timelock);
        assertEq(legacy.quorumNumerator(), 4);
    }

    function testMigrationRejectsZeroTokenAndCanRetry() public {
        vm.prank(timelock);
        vm.expectRevert("Invalid quorum token");
        legacy.upgradeToAndCall(newImplementation, _migration(address(0), 1));
        vm.prank(timelock);
        legacy.upgradeToAndCall(newImplementation, _migration(TOKEN, 1));
        assertEq(PCEGovernor(payable(address(legacy))).quorum(0), 1);
    }

    function testMigrationRejectsNonTimelockAndReplay() public {
        vm.prank(timelock);
        legacy.upgradeToAndCall(newImplementation, "");
        PCEGovernor upgraded = PCEGovernor(payable(address(legacy)));
        vm.expectRevert("Only timelock");
        upgraded.initializeAbsoluteQuorum(TOKEN, 10);
        vm.prank(timelock);
        upgraded.initializeAbsoluteQuorum(TOKEN, 10);
        vm.prank(timelock);
        vm.expectRevert();
        upgraded.initializeAbsoluteQuorum(TOKEN, 20);
        assertEq(upgraded.quorum(0), 10);
    }

    function testImplementationCannotBeMigrated() public {
        vm.prank(timelock);
        vm.expectRevert();
        PCEGovernor(payable(newImplementation)).initializeAbsoluteQuorum(TOKEN, 1);
    }

    function testExistingAbsoluteQuorumCannotBeOverwritten() public {
        PCEGovernor current = PCEGovernor(
            payable(
                address(
                    new ERC1967Proxy(
                        newImplementation,
                        abi.encodeCall(
                            PCEGovernor.initialize,
                            ("PCE Governor", TOKEN, timelock, 12, 30, 1000 ether, TOKEN, 500_000 ether)
                        )
                    )
                )
            )
        );
        vm.prank(timelock);
        vm.expectRevert("Absolute quorum already configured");
        current.initializeAbsoluteQuorum(TOKEN, 1);
        assertEq(current.quorum(0), 500_000 ether);
    }

    function testQueuedGovernanceProposalExecutesAtomicMigration() public {
        TimelockController lock = TimelockController(payable(timelock));
        lock.grantRole(lock.PROPOSER_ROLE(), address(legacy));
        lock.grantRole(lock.CANCELLER_ROLE(), address(legacy));
        lock.grantRole(lock.EXECUTOR_ROLE(), address(0));
        address[] memory targets = new address[](1);
        targets[0] = address(legacy);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)", newImplementation, _migration(TOKEN, 500_000 ether)
        );
        string memory description = "Configure absolute quorum during upgrade";
        bytes32 descriptionHash = keccak256(bytes(description));
        uint256 id = legacy.propose(targets, values, calls, description);
        vm.roll(legacy.proposalSnapshot(id) + 1);
        legacy.castVote(id, 1);
        vm.roll(legacy.proposalDeadline(id) + 1);
        legacy.queue(targets, values, calls, descriptionHash);
        vm.warp(legacy.proposalEta(id) + 1);
        legacy.execute(targets, values, calls, descriptionHash);
        PCEGovernor upgraded = PCEGovernor(payable(address(legacy)));
        assertEq(upgraded.quorum(0), 500_000 ether);
        assertEq(uint256(upgraded.state(id)), 7); // Executed
        assertEq(upgraded.timelock(), timelock);
    }

    function testLegacyQuorumHistoryNamespaceIsPreserved() public {
        bytes32 namespace = 0xe770710421fd2cad75ad828c61aa98f2d77d423a440b67872d0f65554148e000;
        bytes32 checkpointSlot = keccak256(abi.encode(namespace));
        bytes32 historyLength = vm.load(address(legacy), namespace);
        bytes32 checkpoint = vm.load(address(legacy), checkpointSlot);
        assertEq(uint256(historyLength), 1);
        assertTrue(checkpoint != bytes32(0));
        vm.prank(timelock);
        legacy.upgradeToAndCall(newImplementation, _migration(TOKEN, 500_000 ether));
        assertEq(vm.load(address(legacy), namespace), historyLength);
        assertEq(vm.load(address(legacy), checkpointSlot), checkpoint);
    }
}
