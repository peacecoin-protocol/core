// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { GovernanceSender } from "../src/governance/GovernanceSender.sol";
import { IWormholeRelayer } from "../src/governance/IWormholeInterfaces.sol";

contract MockWormholeRelayer is IWormholeRelayer {
    uint64 public nextSequence = 1;
    uint256 public deliveryPrice = 0.01 ether;

    bytes public lastPayload;
    uint16 public lastTargetChain;
    address public lastTargetAddress;
    uint256 public lastReceiverValue;
    uint256 public lastGasLimit;

    function sendPayloadToEvm(
        uint16 targetChain,
        address targetAddress,
        bytes memory payload,
        uint256 receiverValue,
        uint256 gasLimit
    ) external payable override returns (uint64 sequence) {
        lastTargetChain = targetChain;
        lastTargetAddress = targetAddress;
        lastPayload = payload;
        lastReceiverValue = receiverValue;
        lastGasLimit = gasLimit;
        sequence = nextSequence++;
    }

    function quoteEVMDeliveryPrice(uint16, uint256, uint256)
        external
        view
        override
        returns (uint256 nativePriceQuote, uint256 targetChainRefundPerGasUnused)
    {
        return (deliveryPrice, 0);
    }

    function setDeliveryPrice(uint256 _price) external {
        deliveryPrice = _price;
    }
}

contract GovernanceSenderTest is Test {
    GovernanceSender public sender;
    MockWormholeRelayer public relayer;

    address public owner = address(this);
    address public receiver = address(0xBEEF);
    uint256 public constant GAS_LIMIT = 500_000;

    function setUp() public {
        relayer = new MockWormholeRelayer();
        sender = new GovernanceSender(
            address(relayer),
            receiver,
            GAS_LIMIT,
            owner
        );
    }

    function testConstructor() public view {
        assertEq(address(sender.WORMHOLE_RELAYER()), address(relayer));
        assertEq(sender.governanceReceiver(), receiver);
        assertEq(sender.gasLimit(), GAS_LIMIT);
        assertEq(sender.owner(), owner);
        assertEq(sender.TARGET_CHAIN(), 5);
    }

    function testConstructorRevertsInvalidRelayer() public {
        vm.expectRevert(GovernanceSender.InvalidRelayer.selector);
        new GovernanceSender(address(0), receiver, GAS_LIMIT, owner);
    }

    function testConstructorRevertsInvalidReceiver() public {
        vm.expectRevert(GovernanceSender.InvalidReceiver.selector);
        new GovernanceSender(address(relayer), address(0), GAS_LIMIT, owner);
    }

    function testConstructorRevertsInvalidGasLimit() public {
        vm.expectRevert(GovernanceSender.InvalidGasLimit.selector);
        new GovernanceSender(address(relayer), receiver, 0, owner);
    }

    function testSendCrossChainGovernance() public {
        address[] memory targets = new address[](1);
        targets[0] = address(0x1234);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("mint(address,uint256)", address(0x5678), 100 ether);
        bytes32 salt = keccak256("test-salt");

        uint256 fee = sender.quoteDeliveryPrice();
        sender.sendCrossChainGovernance{ value: fee }(targets, values, calldatas, salt);

        // Verify relayer was called correctly
        assertEq(relayer.lastTargetChain(), 5);
        assertEq(relayer.lastTargetAddress(), receiver);
        assertEq(relayer.lastReceiverValue(), 0);
        assertEq(relayer.lastGasLimit(), GAS_LIMIT);

        // Verify payload encoding
        (
            address[] memory decodedTargets,
            uint256[] memory decodedValues,
            bytes[] memory decodedCalldatas,
            bytes32 decodedSalt
        ) = abi.decode(relayer.lastPayload(), (address[], uint256[], bytes[], bytes32));
        assertEq(decodedTargets[0], targets[0]);
        assertEq(decodedValues[0], values[0]);
        assertEq(decodedCalldatas[0], calldatas[0]);
        assertEq(decodedSalt, salt);
    }

    function testSendCrossChainGovernanceBatch() public {
        address[] memory targets = new address[](2);
        targets[0] = address(0x1234);
        targets[1] = address(0x5678);
        uint256[] memory values = new uint256[](2);
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeWithSignature("mint(address,uint256)", address(0xABCD), 100 ether);
        calldatas[1] = abi.encodeWithSignature("setMetaTransactionGas(uint256)", 50000);
        bytes32 salt = keccak256("batch-salt");

        uint256 fee = sender.quoteDeliveryPrice();
        sender.sendCrossChainGovernance{ value: fee }(targets, values, calldatas, salt);

        assertEq(relayer.lastTargetChain(), 5);
    }

    function testSendRevertsOnlyOwner() public {
        address[] memory targets = new address[](1);
        targets[0] = address(0x1234);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = hex"";
        bytes32 salt = keccak256("salt");

        address unauthorized = address(0xDEAD);
        vm.deal(unauthorized, 1 ether);
        vm.prank(unauthorized);
        vm.expectRevert();
        sender.sendCrossChainGovernance{ value: 0.01 ether }(targets, values, calldatas, salt);
    }

    function testSendRevertsEmptyProposal() public {
        address[] memory targets = new address[](0);
        uint256[] memory values = new uint256[](0);
        bytes[] memory calldatas = new bytes[](0);

        vm.expectRevert(GovernanceSender.EmptyProposal.selector);
        sender.sendCrossChainGovernance(targets, values, calldatas, bytes32(0));
    }

    function testSendRevertsArrayLengthMismatch() public {
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](2);

        vm.expectRevert(GovernanceSender.ArrayLengthMismatch.selector);
        sender.sendCrossChainGovernance(targets, values, calldatas, bytes32(0));
    }

    function testSendRevertsInsufficientFee() public {
        address[] memory targets = new address[](1);
        targets[0] = address(0x1234);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = hex"";

        vm.expectRevert(
            abi.encodeWithSelector(GovernanceSender.InsufficientFee.selector, 0.01 ether, 0)
        );
        sender.sendCrossChainGovernance{ value: 0 }(targets, values, calldatas, bytes32(0));
    }

    function testQuoteDeliveryPrice() public view {
        uint256 price = sender.quoteDeliveryPrice();
        assertEq(price, 0.01 ether);
    }

    function testSetGovernanceReceiver() public {
        address newReceiver = address(0xCAFE);
        sender.setGovernanceReceiver(newReceiver);
        assertEq(sender.governanceReceiver(), newReceiver);
    }

    function testSetGovernanceReceiverRevertsInvalid() public {
        vm.expectRevert(GovernanceSender.InvalidReceiver.selector);
        sender.setGovernanceReceiver(address(0));
    }

    function testSetGovernanceReceiverRevertsOnlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        sender.setGovernanceReceiver(address(0xCAFE));
    }

    function testSetGasLimit() public {
        sender.setGasLimit(1_000_000);
        assertEq(sender.gasLimit(), 1_000_000);
    }

    function testSetGasLimitRevertsInvalid() public {
        vm.expectRevert(GovernanceSender.InvalidGasLimit.selector);
        sender.setGasLimit(0);
    }

    function testSetGasLimitRevertsOnlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        sender.setGasLimit(1_000_000);
    }

    function testEmitsCrossChainGovernanceSent() public {
        address[] memory targets = new address[](1);
        targets[0] = address(0x1234);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = hex"";
        bytes32 salt = keccak256("event-salt");

        uint256 fee = sender.quoteDeliveryPrice();

        vm.expectEmit(true, false, false, true);
        emit GovernanceSender.CrossChainGovernanceSent(1, targets, values, salt);

        sender.sendCrossChainGovernance{ value: fee }(targets, values, calldatas, salt);
    }

    function testWithdrawETH() public {
        // Pre-fund the sender
        vm.deal(address(sender), 1 ether);
        assertEq(address(sender).balance, 1 ether);

        address payable recipient = payable(address(0xCAFE));
        sender.withdrawETH(recipient, 0.5 ether);
        assertEq(recipient.balance, 0.5 ether);
        assertEq(address(sender).balance, 0.5 ether);
    }

    function testWithdrawETHRevertsOnlyOwner() public {
        vm.deal(address(sender), 1 ether);
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        sender.withdrawETH(payable(address(0xCAFE)), 0.5 ether);
    }

    function testReceiveETH() public {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(sender).call{ value: 1 ether }("");
        assertTrue(success);
        assertEq(address(sender).balance, 1 ether);
    }
}
