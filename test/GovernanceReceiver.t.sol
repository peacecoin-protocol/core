// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {GovernanceReceiver, IWormholeReceiver} from "../src/governance/GovernanceReceiver.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @dev Mock Wormhole Core Bridge that returns configurable VM results
contract MockWormholeBridge {
    IWormholeReceiver.VM public lastVM;
    bool public valid = true;
    string public reason = "";

    function setValid(bool _valid, string memory _reason) external {
        valid = _valid;
        reason = _reason;
    }

    function setVM(IWormholeReceiver.VM memory _vm) external {
        lastVM = _vm;
    }

    function parseAndVerifyVM(bytes calldata)
        external view returns (IWormholeReceiver.VM memory, bool, string memory)
    {
        return (lastVM, valid, reason);
    }
}

contract GovernanceReceiverTest is Test {
    GovernanceReceiver public receiver;
    TimelockController public timelock;
    MockWormholeBridge public wormhole;

    address public owner = address(this);
    bytes32 public senderAddr = bytes32(uint256(uint160(address(0x5EED))));
    uint256 public constant TIMELOCK_DELAY = 1 days;

    function setUp() public {
        wormhole = new MockWormholeBridge();

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, owner);

        receiver = new GovernanceReceiver(address(wormhole), address(timelock), owner);
        receiver.setGovernanceSender(senderAddr);

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(receiver));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(receiver));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), owner);
    }

    function _makeVM(bytes memory payload, uint64 sequence) internal view returns (IWormholeReceiver.VM memory vm) {
        vm.version = 1;
        vm.timestamp = uint32(block.timestamp);
        vm.emitterChainId = 2; // Ethereum
        vm.emitterAddress = senderAddr;
        vm.sequence = sequence;
        vm.consistencyLevel = 1;
        vm.payload = payload;
    }

    function _encodePayload(
        address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 salt
    ) internal view returns (bytes memory) {
        return abi.encode(targets, values, calldatas, salt, address(receiver), uint16(5));
    }

    function testConstructor() public view {
        assertEq(address(receiver.WORMHOLE()), address(wormhole));
        assertEq(address(receiver.TIMELOCK()), address(timelock));
        assertEq(receiver.SOURCE_CHAIN(), 2);
    }

    function testConstructorRevertsInvalidTimelock() public {
        vm.expectRevert(GovernanceReceiver.InvalidTimelock.selector);
        new GovernanceReceiver(address(wormhole), address(0), owner);
    }

    function testReceiveMessageSchedulesOnTimelock() public {
        address[] memory targets = new address[](1);
        targets[0] = address(0x1234);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = hex"";
        bytes32 salt = keccak256("test");

        bytes memory payload = _encodePayload(targets, values, calldatas, salt);
        wormhole.setVM(_makeVM(payload, 0));

        receiver.receiveMessage(hex"00"); // dummy VAA bytes (mock ignores)

        bytes32 timelockId = timelock.hashOperationBatch(targets, values, calldatas, bytes32(0), salt);
        assertTrue(timelock.isOperationPending(timelockId));
        assertEq(receiver.nextMinimumSequence(), 1);
    }

    function testReceiveMessageRevertsInvalidVAA() public {
        wormhole.setValid(false, "bad guardian sig");
        vm.expectRevert(abi.encodeWithSelector(GovernanceReceiver.InvalidVAA.selector, "bad guardian sig"));
        receiver.receiveMessage(hex"00");
    }

    function testReceiveMessageRevertsGovernanceSenderNotSet() public {
        GovernanceReceiver fresh = new GovernanceReceiver(address(wormhole), address(timelock), owner);
        wormhole.setVM(_makeVM(hex"", 0));
        vm.expectRevert(GovernanceReceiver.GovernanceSenderNotSet.selector);
        fresh.receiveMessage(hex"00");
    }

    function testReceiveMessageRevertsInvalidEmitterChain() public {
        IWormholeReceiver.VM memory vm_ = _makeVM(hex"", 0);
        vm_.emitterChainId = 4; // not Ethereum
        wormhole.setVM(vm_);
        vm.expectRevert(abi.encodeWithSelector(GovernanceReceiver.InvalidEmitterChain.selector, uint16(4)));
        receiver.receiveMessage(hex"00");
    }

    function testReceiveMessageRevertsInvalidEmitterAddress() public {
        IWormholeReceiver.VM memory vm_ = _makeVM(hex"", 0);
        vm_.emitterAddress = bytes32(uint256(1));
        wormhole.setVM(vm_);
        vm.expectRevert(abi.encodeWithSelector(GovernanceReceiver.InvalidEmitterAddress.selector, bytes32(uint256(1))));
        receiver.receiveMessage(hex"00");
    }

    function testReceiveMessageRevertsReplay() public {
        address[] memory targets = new address[](1);
        targets[0] = address(0x1234);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        bytes32 salt1 = keccak256("first");
        bytes32 salt2 = keccak256("second");

        // First message sequence 0
        wormhole.setVM(_makeVM(_encodePayload(targets, values, calldatas, salt1), 0));
        receiver.receiveMessage(hex"00");

        // Replay with sequence 0 again
        wormhole.setVM(_makeVM(_encodePayload(targets, values, calldatas, salt2), 0));
        vm.expectRevert(abi.encodeWithSelector(GovernanceReceiver.InvalidSequence.selector, uint64(0), uint64(1)));
        receiver.receiveMessage(hex"00");
    }

    function testReceiveMessageRevertsExpired() public {
        IWormholeReceiver.VM memory vm_ = _makeVM(hex"", 0);
        vm_.timestamp = uint32(block.timestamp - 3 days); // expired
        vm_.payload = _encodePayload(new address[](1), new uint256[](1), new bytes[](1), bytes32(0));
        wormhole.setVM(vm_);
        vm.expectRevert(abi.encodeWithSelector(GovernanceReceiver.MessageExpired.selector, vm_.timestamp));
        receiver.receiveMessage(hex"00");
    }

    function testCancelScheduledBatchByOwner() public {
        address[] memory targets = new address[](1);
        targets[0] = address(0x1234);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        bytes32 salt = keccak256("cancel-test");

        wormhole.setVM(_makeVM(_encodePayload(targets, values, calldatas, salt), 0));
        receiver.receiveMessage(hex"00");

        bytes32 id = timelock.hashOperationBatch(targets, values, calldatas, bytes32(0), salt);
        assertTrue(timelock.isOperationPending(id));

        receiver.cancelScheduledBatch(id);
        assertFalse(timelock.isOperationPending(id));
    }

    function testCancelScheduledBatchByGuardian() public {
        address guardian = address(0xAAAA);
        receiver.setEmergencyGuardian(guardian);

        address[] memory targets = new address[](1);
        targets[0] = address(0x1234);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        bytes32 salt = keccak256("guardian-cancel");

        wormhole.setVM(_makeVM(_encodePayload(targets, values, calldatas, salt), 0));
        receiver.receiveMessage(hex"00");

        bytes32 id = timelock.hashOperationBatch(targets, values, calldatas, bytes32(0), salt);
        vm.prank(guardian);
        receiver.cancelScheduledBatch(id);
        assertFalse(timelock.isOperationPending(id));
    }

    function testCancelRevertsUnauthorized() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(GovernanceReceiver.NotOwnerOrGuardian.selector);
        receiver.cancelScheduledBatch(bytes32(0));
    }

    function testSetGovernanceSender() public {
        bytes32 newSender = bytes32(uint256(uint160(address(0xBEEF))));
        receiver.setGovernanceSender(newSender);
        assertEq(receiver.governanceSender(), newSender);
    }

    function testSetGovernanceSenderRevertsInvalid() public {
        vm.expectRevert(GovernanceReceiver.InvalidSender.selector);
        receiver.setGovernanceSender(bytes32(0));
    }

    function testSetEmergencyGuardian() public {
        receiver.setEmergencyGuardian(address(0xBBBB));
        assertEq(receiver.emergencyGuardian(), address(0xBBBB));
    }

    function testSetEmergencyGuardianToZero() public {
        receiver.setEmergencyGuardian(address(0xBBBB));
        receiver.setEmergencyGuardian(address(0));
        assertEq(receiver.emergencyGuardian(), address(0));
    }

    function testReceiveMessageRevertsInvalidDestination() public {
        address[] memory targets = new address[](1);
        targets[0] = address(0x1234);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        bytes32 salt = keccak256("bad-dest");

        // Wrong receiver address
        bytes memory badPayload = abi.encode(targets, values, calldatas, salt, address(0xDEAD), uint16(5));
        wormhole.setVM(_makeVM(badPayload, 0));
        vm.expectRevert(GovernanceReceiver.InvalidDestination.selector);
        receiver.receiveMessage(hex"00");
    }

    function testWithdrawETH() public {
        vm.deal(address(receiver), 1 ether);
        receiver.withdrawETH(payable(address(0xCAFE)), 0.5 ether);
        assertEq(address(0xCAFE).balance, 0.5 ether);
    }

    function testWithdrawETHRevertsNonOwner() public {
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
