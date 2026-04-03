// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {GovernanceReceiver} from "../src/governance/GovernanceReceiver.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {toUniversalAddress} from "wormhole-solidity-sdk/Utils.sol";

/// @dev Harness that exposes GovernanceReceiver internals for testing
contract GovernanceReceiverHarness is GovernanceReceiver {
    constructor(address _coreBridge, address _timelock, address _owner)
        GovernanceReceiver(_coreBridge, _timelock, _owner)
    {}

    /// @dev Expose _executeVaa for direct testing
    function exposed_executeVaa(
        bytes calldata payload,
        uint32 timestamp,
        uint16 peerChain,
        bytes32 peerAddress,
        uint64 sequence,
        uint8 consistencyLevel
    ) external {
        _executeVaa(payload, timestamp, peerChain, peerAddress, sequence, consistencyLevel);
    }
}

/// @dev Mock Ownable ERC20 that mimics PCEToken
contract MockOwnableToken is ERC20, Ownable {
    constructor() ERC20("Mock PCE", "MPCE") Ownable(msg.sender) {}
    function mint(address to, uint256 amount) external onlyOwner { _mint(to, amount); }
}

/// @dev Mock Core Bridge for Polygon
contract MockCoreBridgePolygonHarness {
    function chainId() external pure returns (uint16) { return 5; }
    function messageFee() external pure returns (uint256) { return 0; }
}

/**
 * @title GovernanceReceiverHarnessTest
 * @notice Tests _executeVaa logic directly via harness, plus cancel success path
 */
contract GovernanceReceiverHarnessTest is Test {
    GovernanceReceiverHarness public receiver;
    TimelockController public timelock;
    MockCoreBridgePolygonHarness public coreBridge;
    MockOwnableToken public token;

    address public deployer = address(this);
    bytes32 public senderAddress = toUniversalAddress(address(0x5EED));
    uint256 public constant TIMELOCK_DELAY = 1 days;

    function setUp() public {
        coreBridge = new MockCoreBridgePolygonHarness();
        token = new MockOwnableToken();

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, deployer);

        receiver = new GovernanceReceiverHarness(address(coreBridge), address(timelock), deployer);
        receiver.setGovernanceSender(senderAddress);

        // Grant roles
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(receiver));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(receiver));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0));

        // Transfer token to Timelock
        token.transferOwnership(address(timelock));

        // Renounce admin
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);
    }

    function testExecuteVaaSchedulesBatch() public {
        address mintRecipient = address(0xABCD);
        uint256 mintAmount = 1000 ether;

        address[] memory targets = new address[](1);
        targets[0] = address(token);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("mint(address,uint256)", mintRecipient, mintAmount);
        bytes32 salt = keccak256("harness-test-1");

        bytes memory payload = abi.encode(targets, values, calldatas, salt);

        // Call _executeVaa directly
        receiver.exposed_executeVaa(payload, uint32(block.timestamp), 2, senderAddress, 1, 1);

        // Verify operation is pending on Timelock
        bytes32 timelockId = timelock.hashOperationBatch(targets, values, calldatas, bytes32(0), salt);
        assertTrue(timelock.isOperationPending(timelockId));

        // Wait and execute
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        assertTrue(timelock.isOperationReady(timelockId));

        timelock.executeBatch(targets, values, calldatas, bytes32(0), salt);
        assertTrue(timelock.isOperationDone(timelockId));

        // Verify token minted
        assertEq(token.balanceOf(mintRecipient), mintAmount);
    }

    function testExecuteVaaBatchOperations() public {
        address mintRecipient = address(0xABCD);

        address[] memory targets = new address[](1);
        targets[0] = address(token);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("mint(address,uint256)", mintRecipient, 500 ether);
        bytes32 salt = keccak256("harness-batch-1");

        bytes memory payload = abi.encode(targets, values, calldatas, salt);
        receiver.exposed_executeVaa(payload, uint32(block.timestamp), 2, senderAddress, 2, 1);

        // Wait and execute
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        timelock.executeBatch(targets, values, calldatas, bytes32(0), salt);

        assertEq(token.balanceOf(mintRecipient), 500 ether);
    }

    function testCancelScheduledBatchSuccess() public {
        // Schedule via _executeVaa
        address[] memory targets = new address[](1);
        targets[0] = address(token);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("mint(address,uint256)", address(0xABCD), 100 ether);
        bytes32 salt = keccak256("cancel-test");

        bytes memory payload = abi.encode(targets, values, calldatas, salt);
        receiver.exposed_executeVaa(payload, uint32(block.timestamp), 2, senderAddress, 3, 1);

        bytes32 timelockId = timelock.hashOperationBatch(targets, values, calldatas, bytes32(0), salt);
        assertTrue(timelock.isOperationPending(timelockId));

        // Owner cancels
        receiver.cancelScheduledBatch(timelockId);
        assertFalse(timelock.isOperationPending(timelockId));
    }

    function testCancelScheduledBatchByGuardianSuccess() public {
        address guardian = address(0xAAAA);
        receiver.setEmergencyGuardian(guardian);

        // Schedule
        address[] memory targets = new address[](1);
        targets[0] = address(token);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("mint(address,uint256)", address(0xABCD), 100 ether);
        bytes32 salt = keccak256("guardian-cancel-test");

        bytes memory payload = abi.encode(targets, values, calldatas, salt);
        receiver.exposed_executeVaa(payload, uint32(block.timestamp), 2, senderAddress, 4, 1);

        bytes32 timelockId = timelock.hashOperationBatch(targets, values, calldatas, bytes32(0), salt);

        // Guardian cancels
        vm.prank(guardian);
        receiver.cancelScheduledBatch(timelockId);
        assertFalse(timelock.isOperationPending(timelockId));
    }

    function testCannotExecuteBeforeDelay() public {
        address[] memory targets = new address[](1);
        targets[0] = address(token);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("mint(address,uint256)", address(0xABCD), 100 ether);
        bytes32 salt = keccak256("too-early");

        bytes memory payload = abi.encode(targets, values, calldatas, salt);
        receiver.exposed_executeVaa(payload, uint32(block.timestamp), 2, senderAddress, 5, 1);

        vm.expectRevert();
        timelock.executeBatch(targets, values, calldatas, bytes32(0), salt);
    }
}
