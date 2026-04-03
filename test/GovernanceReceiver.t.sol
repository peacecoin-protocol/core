// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {GovernanceReceiver} from "../src/governance/GovernanceReceiver.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {toUniversalAddress} from "wormhole-solidity-sdk/Utils.sol";

/// @dev Minimal mock for Wormhole Core Bridge on Polygon
contract MockCoreBridgePolygon {
    function chainId() external pure returns (uint16) { return 5; } // Polygon
    function messageFee() external pure returns (uint256) { return 0; }
}

contract GovernanceReceiverTest is Test {
    GovernanceReceiver public receiver;
    TimelockController public timelock;
    MockCoreBridgePolygon public coreBridge;

    address public owner = address(this);
    bytes32 public governanceSender = toUniversalAddress(address(0x5EED));

    uint256 public constant TIMELOCK_DELAY = 1 days;

    function setUp() public {
        coreBridge = new MockCoreBridgePolygon();

        // Deploy TimelockController
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, owner);

        // Deploy GovernanceReceiver
        receiver = new GovernanceReceiver(address(coreBridge), address(timelock), owner);

        // Set governance sender
        receiver.setGovernanceSender(governanceSender);

        // Grant roles to receiver
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(receiver));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(receiver));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0));

        // Renounce admin
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), owner);
    }

    function testConstructor() public view {
        assertEq(address(receiver.TIMELOCK()), address(timelock));
        assertEq(receiver.owner(), owner);
        assertEq(receiver.SOURCE_CHAIN(), 2); // Ethereum
    }

    function testConstructorRevertsInvalidTimelock() public {
        vm.expectRevert(GovernanceReceiver.InvalidTimelock.selector);
        new GovernanceReceiver(address(coreBridge), address(0), owner);
    }

    function testSetGovernanceSender() public {
        GovernanceReceiver newReceiver = new GovernanceReceiver(
            address(coreBridge), address(timelock), owner
        );
        bytes32 newSender = toUniversalAddress(address(0xBEEF));
        newReceiver.setGovernanceSender(newSender);
        assertEq(newReceiver.governanceSender(), newSender);
    }

    function testSetGovernanceSenderRevertsInvalid() public {
        vm.expectRevert(GovernanceReceiver.InvalidSender.selector);
        receiver.setGovernanceSender(bytes32(0));
    }

    function testSetGovernanceSenderRevertsOnlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        receiver.setGovernanceSender(toUniversalAddress(address(0xBEEF)));
    }

    function testGovernanceSenderNotSet() public {
        GovernanceReceiver freshReceiver = new GovernanceReceiver(
            address(coreBridge), address(timelock), owner
        );
        // governanceSender not set — _checkPeer should revert
        // We can't easily call executeVAAv1 without a valid VAA, but we test the setter path
        assertEq(freshReceiver.governanceSender(), bytes32(0));
    }

    function testCancelScheduledBatchByOwner() public {
        // We need to schedule something first via Timelock directly (since executeVAAv1 needs real VAA)
        // Grant PROPOSER to this test contract temporarily
        // Since admin was renounced, we test cancel path with a direct Timelock schedule
        // For now, test the access control
        vm.expectRevert(); // will fail because no such operation exists
        receiver.cancelScheduledBatch(bytes32(uint256(1)));
    }

    function testCancelScheduledBatchByGuardian() public {
        address guardian = address(0xAAAA);
        receiver.setEmergencyGuardian(guardian);

        vm.prank(guardian);
        vm.expectRevert(); // no such operation
        receiver.cancelScheduledBatch(bytes32(uint256(1)));
    }

    function testCancelScheduledBatchRevertsUnauthorized() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(GovernanceReceiver.NotOwnerOrGuardian.selector);
        receiver.cancelScheduledBatch(bytes32(0));
    }

    function testSetEmergencyGuardian() public {
        address guardian = address(0xBBBB);
        receiver.setEmergencyGuardian(guardian);
        assertEq(receiver.emergencyGuardian(), guardian);
    }

    function testSetEmergencyGuardianToZeroDisables() public {
        receiver.setEmergencyGuardian(address(0xBBBB));
        receiver.setEmergencyGuardian(address(0));
        assertEq(receiver.emergencyGuardian(), address(0));
    }

    function testSetEmergencyGuardianRevertsOnlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        receiver.setEmergencyGuardian(address(0xBBBB));
    }

    function testWithdrawETH() public {
        vm.deal(address(receiver), 1 ether);
        address payable recipient = payable(address(0xCAFE));
        receiver.withdrawETH(recipient, 0.5 ether);
        assertEq(recipient.balance, 0.5 ether);
        assertEq(address(receiver).balance, 0.5 ether);
    }

    function testWithdrawETHRevertsOnlyOwner() public {
        vm.deal(address(receiver), 1 ether);
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        receiver.withdrawETH(payable(address(0xCAFE)), 0.5 ether);
    }

    function testWithdrawETHRevertsZeroAddress() public {
        vm.deal(address(receiver), 1 ether);
        vm.expectRevert(GovernanceReceiver.WithdrawFailed.selector);
        receiver.withdrawETH(payable(address(0)), 0.5 ether);
    }
}
