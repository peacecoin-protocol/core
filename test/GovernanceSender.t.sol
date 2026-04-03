// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {GovernanceSender} from "../src/governance/GovernanceSender.sol";

contract MockWormholeCore {
    uint64 public nextSequence = 1;
    uint256 public fee = 0.001 ether;
    bytes public lastPayload;
    uint8 public lastConsistencyLevel;

    function publishMessage(uint32, bytes memory payload, uint8 consistencyLevel)
        external payable returns (uint64 sequence)
    {
        require(msg.value == fee, "wrong fee");
        lastPayload = payload;
        lastConsistencyLevel = consistencyLevel;
        sequence = nextSequence++;
    }

    function messageFee() external view returns (uint256) { return fee; }
}

contract GovernanceSenderTest is Test {
    GovernanceSender public sender;
    MockWormholeCore public wormhole;
    address public owner = address(this);
    address public receiver = address(0xBEEF);

    function setUp() public {
        wormhole = new MockWormholeCore();
        sender = new GovernanceSender(address(wormhole), receiver, owner);
        vm.deal(address(sender), 1 ether);
    }

    function testConstructor() public view {
        assertEq(address(sender.WORMHOLE()), address(wormhole));
        assertEq(sender.governanceReceiver(), receiver);
        assertEq(sender.owner(), owner);
        assertEq(sender.TARGET_CHAIN(), 5);
    }

    function testConstructorRevertsInvalidWormhole() public {
        vm.expectRevert(GovernanceSender.InvalidWormhole.selector);
        new GovernanceSender(address(0), receiver, owner);
    }

    function testConstructorRevertsInvalidReceiver() public {
        vm.expectRevert(GovernanceSender.InvalidReceiver.selector);
        new GovernanceSender(address(wormhole), address(0), owner);
    }

    function testQuoteDeliveryPrice() public view {
        assertEq(sender.quoteDeliveryPrice(), 0.001 ether);
    }

    function testSendCrossChainGovernance() public {
        address[] memory targets = new address[](1);
        targets[0] = address(0x1234);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("mint(address,uint256)", address(0x5678), 100 ether);
        bytes32 salt = keccak256("test-salt");

        vm.expectEmit(true, false, false, true);
        emit GovernanceSender.CrossChainGovernanceSent(1, targets, values, salt);
        sender.sendCrossChainGovernance(targets, values, calldatas, salt);

        (address[] memory t,,, bytes32 s, address r, uint16 chain) =
            abi.decode(wormhole.lastPayload(), (address[], uint256[], bytes[], bytes32, address, uint16));
        assertEq(t[0], address(0x1234));
        assertEq(s, salt);
        assertEq(r, receiver);
        assertEq(chain, 5);
    }

    function testSendRevertsOnlyOwner() public {
        address[] memory targets = new address[](1);
        targets[0] = address(0x1234);
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        sender.sendCrossChainGovernance(targets, new uint256[](1), new bytes[](1), bytes32(0));
    }

    function testSendRevertsEmptyProposal() public {
        vm.expectRevert(GovernanceSender.EmptyProposal.selector);
        sender.sendCrossChainGovernance(new address[](0), new uint256[](0), new bytes[](0), bytes32(0));
    }

    function testSendRevertsArrayLengthMismatch() public {
        vm.expectRevert(GovernanceSender.ArrayLengthMismatch.selector);
        sender.sendCrossChainGovernance(new address[](2), new uint256[](1), new bytes[](2), bytes32(0));
    }

    function testSendRevertsInsufficientFee() public {
        GovernanceSender unfunded = new GovernanceSender(address(wormhole), receiver, owner);
        address[] memory targets = new address[](1);
        targets[0] = address(0x1234);
        vm.expectRevert(abi.encodeWithSelector(GovernanceSender.InsufficientFee.selector, 0.001 ether, 0));
        unfunded.sendCrossChainGovernance(targets, new uint256[](1), new bytes[](1), bytes32(0));
    }

    function testSetGovernanceReceiver() public {
        sender.setGovernanceReceiver(address(0xCAFE));
        assertEq(sender.governanceReceiver(), address(0xCAFE));
    }

    function testSetGovernanceReceiverRevertsInvalid() public {
        vm.expectRevert(GovernanceSender.InvalidReceiver.selector);
        sender.setGovernanceReceiver(address(0));
    }

    function testWithdrawETH() public {
        address payable r = payable(address(0xCAFE));
        sender.withdrawETH(r, 0.5 ether);
        assertEq(r.balance, 0.5 ether);
    }

    function testWithdrawETHRevertsZeroAddress() public {
        vm.expectRevert(GovernanceSender.WithdrawFailed.selector);
        sender.withdrawETH(payable(address(0)), 0.5 ether);
    }

    function testReceiveETH() public {
        vm.deal(address(this), 0.1 ether);
        (bool success,) = address(sender).call{value: 0.1 ether}("");
        assertTrue(success);
    }
}
