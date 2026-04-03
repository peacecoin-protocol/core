// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {GovernanceSender} from "../src/governance/GovernanceSender.sol";

/// @dev Minimal mock for Wormhole Core Bridge
contract MockCoreBridge {
    uint64 public nextSequence = 1;

    function chainId() external pure returns (uint16) { return 2; } // Ethereum
    function messageFee() external pure returns (uint256) { return 0.001 ether; }

    function publishMessage(uint32, bytes memory, uint8) external payable returns (uint64 sequence) {
        sequence = nextSequence++;
    }
}

/// @dev Minimal mock for ExecutorQuoterRouter
contract MockExecutorQuoterRouter {
    uint256 public executionFee = 0.009 ether;

    function quoteExecution(uint16, bytes32, address, address, bytes calldata, bytes calldata)
        external view returns (uint256)
    {
        return executionFee;
    }

    function requestExecution(uint16, bytes32, address, address, bytes calldata, bytes calldata)
        external payable
    {}

    function setExecutionFee(uint256 _fee) external { executionFee = _fee; }
}

contract GovernanceSenderTest is Test {
    GovernanceSender public sender;
    MockCoreBridge public coreBridge;
    MockExecutorQuoterRouter public quoterRouter;

    address public owner = address(this);
    bytes32 public receiver = bytes32(uint256(uint160(address(0xBEEF))));
    address public quoter = address(0xAAAA);
    uint128 public constant GAS_LIMIT = 500_000;

    function setUp() public {
        coreBridge = new MockCoreBridge();
        quoterRouter = new MockExecutorQuoterRouter();
        vm.etch(quoter, hex"00"); // quoter must have code

        sender = new GovernanceSender(
            address(coreBridge),
            address(quoterRouter),
            receiver,
            GAS_LIMIT,
            quoter,
            owner
        );

        // Pre-fund sender
        vm.deal(address(sender), 1 ether);
    }

    function testConstructor() public view {
        assertEq(sender.governanceReceiver(), receiver);
        assertEq(sender.gasLimit(), GAS_LIMIT);
        assertEq(sender.quoterAddress(), quoter);
        assertEq(sender.owner(), owner);
        assertEq(sender.TARGET_CHAIN(), 5); // Polygon
    }

    function testConstructorRevertsInvalidReceiver() public {
        vm.expectRevert(GovernanceSender.InvalidReceiver.selector);
        new GovernanceSender(address(coreBridge), address(quoterRouter), bytes32(0), GAS_LIMIT, quoter, owner);
    }

    function testConstructorRevertsInvalidGasLimit() public {
        vm.expectRevert(GovernanceSender.InvalidGasLimit.selector);
        new GovernanceSender(address(coreBridge), address(quoterRouter), receiver, 0, quoter, owner);
    }

    function testConstructorRevertsInvalidQuoter() public {
        vm.expectRevert(GovernanceSender.InvalidQuoter.selector);
        new GovernanceSender(address(coreBridge), address(quoterRouter), receiver, GAS_LIMIT, address(0), owner);
    }

    function testQuoteDeliveryPrice() public view {
        uint256 price = sender.quoteDeliveryPrice();
        // executionFee (0.009) + messageFee (0.001) = 0.01 ether
        assertEq(price, 0.01 ether);
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
    }

    function testSendRevertsOnlyOwner() public {
        address[] memory targets = new address[](1);
        targets[0] = address(0x1234);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = hex"";

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        sender.sendCrossChainGovernance(targets, values, calldatas, bytes32(0));
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
        // Deploy unfunded sender
        GovernanceSender unfunded = new GovernanceSender(
            address(coreBridge), address(quoterRouter), receiver, GAS_LIMIT, quoter, owner
        );

        address[] memory targets = new address[](1);
        targets[0] = address(0x1234);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = hex"";

        vm.expectRevert(
            abi.encodeWithSelector(GovernanceSender.InsufficientFee.selector, 0.01 ether, 0)
        );
        unfunded.sendCrossChainGovernance(targets, values, calldatas, bytes32(0));
    }

    function testSetGovernanceReceiver() public {
        bytes32 newReceiver = bytes32(uint256(uint160(address(0xCAFE))));
        sender.setGovernanceReceiver(newReceiver);
        assertEq(sender.governanceReceiver(), newReceiver);
    }

    function testSetGovernanceReceiverRevertsInvalid() public {
        vm.expectRevert(GovernanceSender.InvalidReceiver.selector);
        sender.setGovernanceReceiver(bytes32(0));
    }

    function testSetGasLimit() public {
        sender.setGasLimit(1_000_000);
        assertEq(sender.gasLimit(), 1_000_000);
    }

    function testSetGasLimitRevertsInvalid() public {
        vm.expectRevert(GovernanceSender.InvalidGasLimit.selector);
        sender.setGasLimit(0);
    }

    function testSetQuoterAddress() public {
        address newQuoter = address(0xBBBB);
        vm.etch(newQuoter, hex"00");
        sender.setQuoterAddress(newQuoter);
        assertEq(sender.quoterAddress(), newQuoter);
    }

    function testSetQuoterAddressRevertsInvalid() public {
        vm.expectRevert(GovernanceSender.InvalidQuoter.selector);
        sender.setQuoterAddress(address(0));
    }

    function testWithdrawETH() public {
        address payable recipient = payable(address(0xCAFE));
        sender.withdrawETH(recipient, 0.5 ether);
        assertEq(recipient.balance, 0.5 ether);
    }

    function testWithdrawETHRevertsOnlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        sender.withdrawETH(payable(address(0xCAFE)), 0.5 ether);
    }

    function testWithdrawETHRevertsZeroAddress() public {
        vm.expectRevert(GovernanceSender.WithdrawFailed.selector);
        sender.withdrawETH(payable(address(0)), 0.5 ether);
    }

    function testReceiveETH() public {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(sender).call{value: 1 ether}("");
        assertTrue(success);
    }
}
