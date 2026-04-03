// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { GovernanceReceiver } from "../src/governance/GovernanceReceiver.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

contract GovernanceReceiverTest is Test {
    GovernanceReceiver public receiver;
    TimelockController public timelock;

    address public owner = address(this);
    address public wormholeRelayer = address(0xEE01);
    address public governanceSender = address(0x5EED);

    uint256 public constant TIMELOCK_DELAY = 1 days;

    function setUp() public {
        // Etch code at mock addresses so code.length > 0 checks pass
        vm.etch(wormholeRelayer, hex"00");
        vm.etch(governanceSender, hex"00");

        // Deploy TimelockController with empty proposers/executors
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);

        timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, owner);

        // Deploy GovernanceReceiver
        receiver = new GovernanceReceiver(wormholeRelayer, address(timelock), owner);

        // Set governance sender
        receiver.setGovernanceSender(governanceSender);

        // Grant PROPOSER_ROLE to receiver
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(receiver));

        // Grant CANCELLER_ROLE to receiver (matches deploy script)
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(receiver));

        // Grant EXECUTOR_ROLE to anyone
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0));

        // Renounce admin role
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), owner);
    }

    function testConstructor() public view {
        assertEq(receiver.WORMHOLE_RELAYER(), wormholeRelayer);
        assertEq(address(receiver.TIMELOCK()), address(timelock));
        assertEq(receiver.owner(), owner);
        assertEq(receiver.SOURCE_CHAIN(), 2);
    }

    function testSetGovernanceSender() public {
        GovernanceReceiver newReceiver = new GovernanceReceiver(
            wormholeRelayer, address(timelock), owner
        );
        address newSender = address(0xBEEF);
        newReceiver.setGovernanceSender(newSender);
        assertEq(newReceiver.governanceSender(), newSender);
    }

    function testSetGovernanceSenderRevertsInvalid() public {
        vm.expectRevert(GovernanceReceiver.InvalidSender.selector);
        receiver.setGovernanceSender(address(0));
    }

    function testSetGovernanceSenderRevertsOnlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        receiver.setGovernanceSender(address(0xBEEF));
    }

    function testReceiveWormholeMessages() public {
        address[] memory targets = new address[](1);
        targets[0] = address(0x1234);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("mint(address,uint256)", address(0x5678), 100 ether);
        bytes32 salt = keccak256("test-salt");

        bytes memory payload = abi.encode(targets, values, calldatas, salt);
        bytes32 sourceAddress = bytes32(uint256(uint160(governanceSender)));
        bytes32 deliveryHash = keccak256("delivery-1");

        // Call from wormhole relayer
        vm.prank(wormholeRelayer);
        receiver.receiveWormholeMessages(payload, new bytes[](0), sourceAddress, 2, deliveryHash);

        // Verify delivery was processed
        assertTrue(receiver.processedDeliveries(deliveryHash));

        // Verify operation was scheduled on timelock
        bytes32 timelockId = timelock.hashOperationBatch(
            targets, values, calldatas, bytes32(0), salt
        );
        assertTrue(timelock.isOperationPending(timelockId));
    }

    function testReceiveRevertsUnauthorizedRelayer() public {
        bytes memory payload = hex"";
        bytes32 sourceAddress = bytes32(uint256(uint160(governanceSender)));

        vm.prank(address(0xDEAD));
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceReceiver.UnauthorizedRelayer.selector, address(0xDEAD))
        );
        receiver.receiveWormholeMessages(payload, new bytes[](0), sourceAddress, 2, bytes32(0));
    }

    function testReceiveRevertsInvalidSourceChain() public {
        bytes memory payload = hex"";
        bytes32 sourceAddress = bytes32(uint256(uint160(governanceSender)));

        vm.prank(wormholeRelayer);
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceReceiver.InvalidSourceChain.selector, uint16(4))
        );
        receiver.receiveWormholeMessages(payload, new bytes[](0), sourceAddress, 4, bytes32(0));
    }

    function testReceiveRevertsInvalidSourceAddress() public {
        bytes memory payload = hex"";
        bytes32 wrongAddress = bytes32(uint256(uint160(address(0xDEAD))));

        vm.prank(wormholeRelayer);
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceReceiver.InvalidSourceAddress.selector, wrongAddress)
        );
        receiver.receiveWormholeMessages(payload, new bytes[](0), wrongAddress, 2, bytes32(0));
    }

    function testReceiveRevertsReplayAttack() public {
        address[] memory targets = new address[](1);
        targets[0] = address(0x1234);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = hex"";
        bytes32 salt = keccak256("replay-salt");

        bytes memory payload = abi.encode(targets, values, calldatas, salt);
        bytes32 sourceAddress = bytes32(uint256(uint160(governanceSender)));
        bytes32 deliveryHash = keccak256("delivery-replay");

        // First delivery succeeds
        vm.prank(wormholeRelayer);
        receiver.receiveWormholeMessages(payload, new bytes[](0), sourceAddress, 2, deliveryHash);

        // Second delivery with same hash reverts
        vm.prank(wormholeRelayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceReceiver.DeliveryAlreadyProcessed.selector, deliveryHash
            )
        );
        receiver.receiveWormholeMessages(payload, new bytes[](0), sourceAddress, 2, deliveryHash);
    }

    function testReceiveRevertsGovernanceSenderNotSet() public {
        GovernanceReceiver freshReceiver = new GovernanceReceiver(
            wormholeRelayer, address(timelock), owner
        );
        // governanceSender not set (default address(0))
        bytes32 sourceAddress = bytes32(uint256(uint160(governanceSender)));
        vm.prank(wormholeRelayer);
        vm.expectRevert(GovernanceReceiver.GovernanceSenderNotSet.selector);
        freshReceiver.receiveWormholeMessages(hex"", new bytes[](0), sourceAddress, 2, bytes32(0));
    }

    function testCancelScheduledBatchByOwner() public {
        // Schedule an operation via receiveWormholeMessages
        address[] memory targets = new address[](1);
        targets[0] = address(0x1234);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = hex"";
        bytes32 salt = keccak256("cancel-salt");

        bytes memory payload = abi.encode(targets, values, calldatas, salt);
        bytes32 sourceAddress = bytes32(uint256(uint160(governanceSender)));

        vm.prank(wormholeRelayer);
        receiver.receiveWormholeMessages(payload, new bytes[](0), sourceAddress, 2, keccak256("d-cancel"));

        bytes32 timelockId = timelock.hashOperationBatch(targets, values, calldatas, bytes32(0), salt);
        assertTrue(timelock.isOperationPending(timelockId));

        // Owner cancels
        receiver.cancelScheduledBatch(timelockId);
        assertFalse(timelock.isOperationPending(timelockId));
    }

    function testCancelScheduledBatchByGuardian() public {
        address guardian = address(0xAAAA);
        receiver.setEmergencyGuardian(guardian);

        // Schedule an operation
        address[] memory targets = new address[](1);
        targets[0] = address(0x1234);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = hex"";
        bytes32 salt = keccak256("guardian-cancel-salt");

        bytes memory payload = abi.encode(targets, values, calldatas, salt);
        bytes32 sourceAddress = bytes32(uint256(uint160(governanceSender)));

        vm.prank(wormholeRelayer);
        receiver.receiveWormholeMessages(payload, new bytes[](0), sourceAddress, 2, keccak256("d-guardian"));

        bytes32 timelockId = timelock.hashOperationBatch(targets, values, calldatas, bytes32(0), salt);

        // Guardian cancels
        vm.prank(guardian);
        receiver.cancelScheduledBatch(timelockId);
        assertFalse(timelock.isOperationPending(timelockId));
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

    function testReceiveEmitsEvent() public {
        address[] memory targets = new address[](1);
        targets[0] = address(0x1234);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = hex"";
        bytes32 salt = keccak256("event-salt");

        bytes memory payload = abi.encode(targets, values, calldatas, salt);
        bytes32 sourceAddress = bytes32(uint256(uint160(governanceSender)));
        bytes32 deliveryHash = keccak256("delivery-event");

        vm.prank(wormholeRelayer);
        vm.expectEmit(true, false, false, true);
        emit GovernanceReceiver.CrossChainGovernanceReceived(deliveryHash, targets, values, salt);
        receiver.receiveWormholeMessages(payload, new bytes[](0), sourceAddress, 2, deliveryHash);
    }

    function testWithdrawETH() public {
        // Fund the receiver
        vm.deal(address(receiver), 1 ether);
        assertEq(address(receiver).balance, 1 ether);

        // Owner withdraws
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
}
