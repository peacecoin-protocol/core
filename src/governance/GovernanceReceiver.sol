// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

interface IWormholeReceiver {
    struct Signature {
        bytes32 r;
        bytes32 s;
        uint8 v;
        uint8 guardianIndex;
    }

    struct VM {
        uint8 version;
        uint32 timestamp;
        uint32 nonce;
        uint16 emitterChainId;
        bytes32 emitterAddress;
        uint64 sequence;
        uint8 consistencyLevel;
        bytes payload;
        uint32 guardianSetIndex;
        Signature[] signatures;
        bytes32 hash;
    }

    function parseAndVerifyVM(bytes calldata encodedVM)
        external view returns (VM memory vm, bool valid, string memory reason);
}

/**
 * @title GovernanceReceiver
 * @notice Polygon-side contract that receives governance proposals from Ethereum via Wormhole VAAs
 * @dev Receives Wormhole VAAs published by GovernanceSender, verifies Guardian signatures,
 *      and schedules operations on a local TimelockController for delayed execution.
 *      Anyone can relay the VAA — this is a permissionless relay model.
 *
 * Flow: GovernanceSender (Ethereum) → Wormhole Core Bridge → VAA
 *       → anyone relays → GovernanceReceiver.receiveMessage(vaa)
 *       → Polygon Timelock → PCEToken
 */
contract GovernanceReceiver is Ownable {
    /// @notice Wormhole chain ID for Ethereum
    uint16 public constant SOURCE_CHAIN = 2;

    /// @notice Wormhole chain ID for Polygon (destination)
    uint16 public constant DESTINATION_CHAIN = 5;

    /// @notice VAA validity period (2 days, matching Uniswap's approach)
    uint256 public constant MESSAGE_TIMEOUT = 2 days;

    /// @notice Wormhole Core Bridge on Polygon
    IWormholeReceiver public immutable WORMHOLE;

    /// @notice Polygon TimelockController for delayed execution
    TimelockController public immutable TIMELOCK;

    /// @notice Address of GovernanceSender on Ethereum (bytes32, left-padded)
    bytes32 public governanceSender;

    /// @notice Emergency guardian for fast cancellation
    address public emergencyGuardian;

    /// @notice Next minimum sequence number (monotonically increasing, replay protection)
    uint64 public nextMinimumSequence;

    event CrossChainGovernanceReceived(
        uint64 indexed sequence,
        address[] targets,
        uint256[] values,
        bytes32 salt
    );
    event GovernanceSenderUpdated(bytes32 indexed oldSender, bytes32 indexed newSender);
    event EmergencyGuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    error InvalidWormhole();
    error InvalidTimelock();
    error InvalidSender();
    error GovernanceSenderNotSet();
    error InvalidVAA(string reason);
    error InvalidEmitterChain(uint16 chainId);
    error InvalidEmitterAddress(bytes32 emitterAddress);
    error InvalidSequence(uint64 sequence, uint64 minimum);
    error MessageExpired(uint32 timestamp);
    error InvalidDestination();
    error NotOwnerOrGuardian();
    error WithdrawFailed();

    /**
     * @param _wormhole Address of the Wormhole Core Bridge on Polygon
     * @param _timelock Address of the Polygon TimelockController
     * @param _owner Initial owner (deployer)
     */
    constructor(
        address _wormhole,
        address _timelock,
        address _owner
    ) Ownable(_owner) {
        if (_wormhole == address(0) || _wormhole.code.length == 0) revert InvalidWormhole();
        if (_timelock == address(0) || _timelock.code.length == 0) revert InvalidTimelock();

        WORMHOLE = IWormholeReceiver(_wormhole);
        TIMELOCK = TimelockController(payable(_timelock));
    }

    /**
     * @notice Receive and process a Wormhole VAA containing a governance proposal
     * @dev Anyone can call this — the VAA's Guardian signatures guarantee authenticity.
     *      Sequence numbers must be monotonically increasing (replay protection).
     * @param whMessage The encoded Wormhole VAA
     */
    function receiveMessage(bytes calldata whMessage) external {
        // Verify VAA via Wormhole Core Bridge (checks Guardian signatures)
        (IWormholeReceiver.VM memory vm, bool valid, string memory reason) = WORMHOLE.parseAndVerifyVM(whMessage);
        if (!valid) revert InvalidVAA(reason);

        // Verify GovernanceSender is configured
        if (governanceSender == bytes32(0)) revert GovernanceSenderNotSet();

        // Verify emitter is GovernanceSender on Ethereum
        if (vm.emitterChainId != SOURCE_CHAIN) revert InvalidEmitterChain(vm.emitterChainId);
        if (vm.emitterAddress != governanceSender) revert InvalidEmitterAddress(vm.emitterAddress);

        // Sequence must be monotonically increasing (replay protection)
        if (vm.sequence < nextMinimumSequence) revert InvalidSequence(vm.sequence, nextMinimumSequence);
        nextMinimumSequence = vm.sequence + 1;

        // Check message is still valid (within timeout)
        if (vm.timestamp + MESSAGE_TIMEOUT < block.timestamp) revert MessageExpired(vm.timestamp);

        // Decode payload
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 salt,
            address messageReceiver,
            uint16 receiverChainId
        ) = abi.decode(vm.payload, (address[], uint256[], bytes[], bytes32, address, uint16));

        // Verify this message is for this contract on this chain
        if (messageReceiver != address(this) || receiverChainId != DESTINATION_CHAIN) revert InvalidDestination();

        // Schedule on Polygon Timelock
        uint256 minDelay = TIMELOCK.getMinDelay();
        TIMELOCK.scheduleBatch(targets, values, calldatas, bytes32(0), salt, minDelay);

        emit CrossChainGovernanceReceived(vm.sequence, targets, values, salt);
    }

    /**
     * @notice Cancel a scheduled batch operation on the Polygon Timelock
     * @dev Callable by owner or emergencyGuardian.
     *      After ownership is transferred to the Polygon Timelock, only emergencyGuardian
     *      provides immediate cancellation.
     * @param id The operation identifier (from hashOperationBatch)
     */
    function cancelScheduledBatch(bytes32 id) external {
        if (msg.sender != owner() && msg.sender != emergencyGuardian) {
            revert NotOwnerOrGuardian();
        }
        TIMELOCK.cancel(id);
    }

    /**
     * @notice Set the GovernanceSender address on Ethereum
     * @param _governanceSender Address in Wormhole format (bytes32, 12 zero bytes + 20-byte address)
     */
    function setGovernanceSender(bytes32 _governanceSender) external onlyOwner {
        if (_governanceSender == bytes32(0)) revert InvalidSender();
        bytes32 old = governanceSender;
        governanceSender = _governanceSender;
        emit GovernanceSenderUpdated(old, _governanceSender);
    }

    /**
     * @notice Set or remove the emergency guardian
     * @param _guardian Address of the emergency guardian, or address(0) to disable
     */
    function setEmergencyGuardian(address _guardian) external onlyOwner {
        address old = emergencyGuardian;
        emergencyGuardian = _guardian;
        emit EmergencyGuardianUpdated(old, _guardian);
    }

    /**
     * @notice Withdraw ETH accidentally sent to this contract
     */
    function withdrawETH(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert WithdrawFailed();
        (bool success,) = to.call{value: amount}("");
        if (!success) revert WithdrawFailed();
    }
}
