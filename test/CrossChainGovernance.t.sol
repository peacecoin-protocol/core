// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { GovernanceSender } from "../src/governance/GovernanceSender.sol";
import { GovernanceReceiver } from "../src/governance/GovernanceReceiver.sol";
import { IWormholeRelayer } from "../src/governance/IWormholeInterfaces.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockOwnableToken
 * @notice Minimal Ownable ERC20 that mimics PCEToken's onlyOwner mint pattern
 */
contract MockOwnableToken is ERC20, Ownable {
    uint256 public metaTransactionGas;

    constructor() ERC20("Mock PCE", "MPCE") Ownable(msg.sender) {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function setMetaTransactionGas(uint256 _gas) external onlyOwner {
        metaTransactionGas = _gas;
    }
}

/**
 * @title MockRelayerBridge
 * @notice Simulates the Wormhole Automatic Relayer for integration testing.
 *         Captures payloads from sendPayloadToEvm and delivers them to the receiver.
 */
contract MockRelayerBridge is IWormholeRelayer {
    uint64 public nextSequence = 1;
    uint256 public deliveryPrice = 0.01 ether;

    // Captured delivery data
    address public lastTargetAddress;
    bytes public lastPayload;
    bytes32 public lastSourceAddress;

    function sendPayloadToEvm(
        uint16,
        address targetAddress,
        bytes memory payload,
        uint256,
        uint256
    ) external payable override returns (uint64 sequence) {
        lastTargetAddress = targetAddress;
        lastPayload = payload;
        lastSourceAddress = bytes32(uint256(uint160(msg.sender)));
        sequence = nextSequence++;
    }

    function quoteEVMDeliveryPrice(uint16, uint256, uint256)
        external
        view
        override
        returns (uint256 nativePriceQuote, uint256)
    {
        return (deliveryPrice, 0);
    }

    /**
     * @notice Simulate Wormhole delivery by calling the receiver with captured data
     * @param deliveryHash Unique delivery hash
     */
    function deliverToReceiver(bytes32 deliveryHash) external {
        GovernanceReceiver(lastTargetAddress).receiveWormholeMessages(
            lastPayload,
            new bytes[](0),
            lastSourceAddress,
            2, // Wormhole chain ID for Ethereum (EVM chainId is 1)
            deliveryHash
        );
    }
}

/**
 * @title CrossChainGovernanceTest
 * @notice End-to-end integration test for cross-chain governance flow.
 *         Simulates the full flow on a single chain:
 *         1. GovernanceSender encodes and sends via mock relayer
 *         2. Mock relayer delivers to GovernanceReceiver
 *         3. GovernanceReceiver schedules on Polygon Timelock
 *         4. After delay, execute on Timelock
 *         5. Verify token state changes
 */
contract CrossChainGovernanceTest is Test {
    GovernanceSender public sender;
    GovernanceReceiver public receiver;
    MockRelayerBridge public relayer;
    TimelockController public polygonTimelock;
    MockOwnableToken public token;

    address public deployer = address(this);
    TimelockController public ethTimelock;
    uint256 public constant POLYGON_TIMELOCK_DELAY = 1 days;
    uint256 public constant ETH_TIMELOCK_DELAY = 2 days;
    uint256 public constant GAS_LIMIT = 500_000;

    function setUp() public {
        // 1. Deploy mock token (simulates PCEToken's Ownable pattern)
        token = new MockOwnableToken();

        // 2. Deploy mock Wormhole relayer
        relayer = new MockRelayerBridge();

        // 3. Deploy Ethereum TimelockController (models production Governor → Timelock flow)
        address[] memory ethProposers = new address[](1);
        ethProposers[0] = deployer; // In production: Governor contract
        address[] memory ethExecutors = new address[](1);
        ethExecutors[0] = address(0); // Anyone can execute
        ethTimelock = new TimelockController(
            ETH_TIMELOCK_DELAY, ethProposers, ethExecutors, deployer
        );

        // 4. Deploy Polygon Timelock (empty proposers/executors, granted explicitly)
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        polygonTimelock = new TimelockController(
            POLYGON_TIMELOCK_DELAY, proposers, executors, deployer
        );

        // 5. Deploy GovernanceReceiver
        receiver = new GovernanceReceiver(
            address(relayer), address(polygonTimelock), deployer
        );

        // 6. Deploy GovernanceSender owned by Ethereum Timelock
        sender = new GovernanceSender(
            address(relayer), address(receiver), GAS_LIMIT, address(ethTimelock)
        );

        // 7. Configure: set sender on receiver
        receiver.setGovernanceSender(address(sender));

        // 8. Grant PROPOSER_ROLE to receiver on Polygon Timelock
        polygonTimelock.grantRole(polygonTimelock.PROPOSER_ROLE(), address(receiver));

        // 8b. Grant CANCELLER_ROLE to receiver (matches deploy script)
        polygonTimelock.grantRole(polygonTimelock.CANCELLER_ROLE(), address(receiver));

        // 8c. Grant EXECUTOR_ROLE to anyone
        polygonTimelock.grantRole(polygonTimelock.EXECUTOR_ROLE(), address(0));

        // 9. Transfer token ownership to Polygon Timelock
        token.transferOwnership(address(polygonTimelock));

        // 10. Renounce Timelock admin
        polygonTimelock.renounceRole(polygonTimelock.DEFAULT_ADMIN_ROLE(), deployer);

        // 11. Fund Ethereum Timelock with ETH for relayer fees
        vm.deal(address(ethTimelock), 10 ether);
    }

    /// @dev Helper: schedule + wait + execute on Ethereum Timelock to call GovernanceSender
    function _executeViaEthTimelock(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 salt
    ) internal {
        // Encode the call to GovernanceSender.sendCrossChainGovernance
        uint256 fee = sender.quoteDeliveryPrice();
        address[] memory ethTargets = new address[](1);
        ethTargets[0] = address(sender);
        uint256[] memory ethValues = new uint256[](1);
        ethValues[0] = fee;
        bytes[] memory ethCalldatas = new bytes[](1);
        ethCalldatas[0] = abi.encodeWithSelector(
            sender.sendCrossChainGovernance.selector, targets, values, calldatas, salt
        );

        // Schedule on Ethereum Timelock (deployer has PROPOSER_ROLE)
        ethTimelock.scheduleBatch(ethTargets, ethValues, ethCalldatas, bytes32(0), salt, ETH_TIMELOCK_DELAY);

        // Wait for Ethereum Timelock delay
        vm.warp(block.timestamp + ETH_TIMELOCK_DELAY + 1);

        // Execute on Ethereum Timelock (anyone can execute)
        ethTimelock.executeBatch(ethTargets, ethValues, ethCalldatas, bytes32(0), salt);
    }

    function testFullCrossChainMint() public {
        // === Step 1: Prepare governance proposal (mint tokens) ===
        address mintRecipient = address(0xABCD);
        uint256 mintAmount = 1000 ether;

        address[] memory targets = new address[](1);
        targets[0] = address(token);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature(
            "mint(address,uint256)", mintRecipient, mintAmount
        );
        bytes32 salt = keccak256("cross-chain-mint-1");

        // === Step 2: Execute via Ethereum Timelock → GovernanceSender → Wormhole ===
        _executeViaEthTimelock(targets, values, calldatas, salt);

        // === Step 3: Wormhole delivers to Polygon ===
        bytes32 deliveryHash = keccak256("delivery-mint-1");
        relayer.deliverToReceiver(deliveryHash);

        // === Step 4: Verify operation is pending on Polygon Timelock ===
        bytes32 timelockId = polygonTimelock.hashOperationBatch(
            targets, values, calldatas, bytes32(0), salt
        );
        assertTrue(polygonTimelock.isOperationPending(timelockId));
        assertFalse(polygonTimelock.isOperationReady(timelockId));

        // === Step 5: Wait for Polygon timelock delay ===
        vm.warp(block.timestamp + POLYGON_TIMELOCK_DELAY + 1);
        assertTrue(polygonTimelock.isOperationReady(timelockId));

        // === Step 6: Execute on Polygon Timelock ===
        polygonTimelock.executeBatch(targets, values, calldatas, bytes32(0), salt);
        assertTrue(polygonTimelock.isOperationDone(timelockId));

        // === Step 7: Verify token state ===
        assertEq(token.balanceOf(mintRecipient), mintAmount);
    }

    function testFullCrossChainBatchOperations() public {
        // Batch: mint + setMetaTransactionGas
        address mintRecipient = address(0xABCD);
        uint256 mintAmount = 500 ether;
        uint256 newGas = 80000;

        address[] memory targets = new address[](2);
        targets[0] = address(token);
        targets[1] = address(token);
        uint256[] memory values = new uint256[](2);
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeWithSignature(
            "mint(address,uint256)", mintRecipient, mintAmount
        );
        calldatas[1] = abi.encodeWithSignature("setMetaTransactionGas(uint256)", newGas);
        bytes32 salt = keccak256("cross-chain-batch-1");

        // Execute via Ethereum Timelock
        _executeViaEthTimelock(targets, values, calldatas, salt);

        // Deliver
        bytes32 deliveryHash = keccak256("delivery-batch-1");
        relayer.deliverToReceiver(deliveryHash);

        // Wait for Polygon delay and execute
        vm.warp(block.timestamp + POLYGON_TIMELOCK_DELAY + 1);
        polygonTimelock.executeBatch(targets, values, calldatas, bytes32(0), salt);

        // Verify both operations succeeded
        assertEq(token.balanceOf(mintRecipient), mintAmount);
        assertEq(token.metaTransactionGas(), newGas);
    }

    function testCannotExecuteBeforeDelay() public {
        address[] memory targets = new address[](1);
        targets[0] = address(token);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature(
            "mint(address,uint256)", address(0xABCD), 100 ether
        );
        bytes32 salt = keccak256("too-early");

        // Execute via Ethereum Timelock and deliver
        _executeViaEthTimelock(targets, values, calldatas, salt);

        bytes32 deliveryHash = keccak256("delivery-too-early");
        relayer.deliverToReceiver(deliveryHash);

        // Try to execute on Polygon before delay — should revert
        vm.expectRevert();
        polygonTimelock.executeBatch(targets, values, calldatas, bytes32(0), salt);
    }

    function testReplayProtection() public {
        address[] memory targets = new address[](1);
        targets[0] = address(token);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature(
            "mint(address,uint256)", address(0xABCD), 100 ether
        );
        bytes32 salt = keccak256("replay-test");

        // Execute via Ethereum Timelock and deliver
        _executeViaEthTimelock(targets, values, calldatas, salt);

        bytes32 deliveryHash = keccak256("delivery-replay-test");
        relayer.deliverToReceiver(deliveryHash);

        // Second delivery with same hash should fail (simulate re-delivery by relayer)
        vm.prank(address(relayer));
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceReceiver.DeliveryAlreadyProcessed.selector, deliveryHash
            )
        );
        relayer.deliverToReceiver(deliveryHash);
    }

    function testOnlyEthTimelockCanSend() public {
        address[] memory targets = new address[](1);
        targets[0] = address(token);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = hex"";

        vm.deal(address(0xDEAD), 1 ether);
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        sender.sendCrossChainGovernance{ value: 0.01 ether }(
            targets, values, calldatas, bytes32(0)
        );
    }
}
