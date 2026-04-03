// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ExecutorReceive, InvalidPeer} from "wormhole-solidity-sdk/Executor/Integration.sol";
import {SequenceReplayProtectionLib} from "wormhole-solidity-sdk/libraries/ReplayProtection.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {CHAIN_ID_ETHEREUM} from "wormhole-solidity-sdk/constants/Chains.sol";

/**
 * @title GovernanceReceiver
 * @notice Polygon-side contract that receives governance proposals from Ethereum via Wormhole Executor
 * @dev Receives cross-chain VAAs from GovernanceSender and schedules them on a
 *      local TimelockController for delayed execution.
 *
 * Flow: GovernanceSender (Ethereum) → Wormhole Executor → GovernanceReceiver → Polygon Timelock → PCEToken
 */
contract GovernanceReceiver is ExecutorReceive, Ownable {
    using SequenceReplayProtectionLib for *;

    /// @notice Wormhole chain ID for Ethereum
    uint16 public constant SOURCE_CHAIN = CHAIN_ID_ETHEREUM;

    /// @notice Polygon TimelockController for delayed execution
    TimelockController public immutable TIMELOCK;

    /// @notice Address of GovernanceSender on Ethereum (bytes32, left-padded)
    bytes32 public governanceSender;

    /// @notice Emergency guardian that can cancel scheduled operations without timelock delay
    address public emergencyGuardian;

    event CrossChainGovernanceReceived(
        uint64 indexed sequence,
        address[] targets,
        uint256[] values,
        bytes32 salt
    );
    event GovernanceSenderUpdated(bytes32 indexed oldSender, bytes32 indexed newSender);
    event EmergencyGuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    error InvalidSender();
    error InvalidTimelock();
    error NotOwnerOrGuardian();
    error GovernanceSenderNotSet();
    error WithdrawFailed();

    /**
     * @param _coreBridge Address of the Wormhole Core Bridge on Polygon
     * @param _timelock Address of the Polygon TimelockController
     * @param _owner Initial owner (deployer)
     */
    constructor(
        address _coreBridge,
        address _timelock,
        address _owner
    ) ExecutorReceive(_coreBridge) Ownable(_owner) {
        if (_timelock == address(0) || _timelock.code.length == 0) revert InvalidTimelock();
        TIMELOCK = TimelockController(payable(_timelock));
    }

    /// @dev Required by ExecutorSharedBase — returns peer address for source chain
    function _getPeer(uint16 chainId) internal view override returns (bytes32) {
        if (chainId == SOURCE_CHAIN) return governanceSender;
        return bytes32(0);
    }

    /// @dev Override to check governanceSender is set and source chain is Ethereum
    function _checkPeer(uint16 chainId, bytes32 peerAddress) internal view override {
        if (governanceSender == bytes32(0)) revert GovernanceSenderNotSet();
        if (chainId != SOURCE_CHAIN) revert InvalidPeer();
        if (governanceSender != peerAddress) revert InvalidPeer();
    }

    /// @dev Replay protection using Wormhole SDK's sequence-based protection
    function _replayProtect(
        uint16 emitterChainId,
        bytes32 emitterAddress,
        uint64 sequence,
        bytes calldata /* encodedVaa */
    ) internal override {
        SequenceReplayProtectionLib.replayProtect(emitterChainId, emitterAddress, sequence);
    }

    // Use default msg.value == 0 check (no override needed)

    /**
     * @dev Process the received VAA payload — decode and schedule on Polygon Timelock
     */
    function _executeVaa(
        bytes calldata payload,
        uint32, /* timestamp */
        uint16, /* peerChain */
        bytes32, /* peerAddress */
        uint64 sequence,
        uint8 /* consistencyLevel */
    ) internal override {
        // Decode payload
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 salt
        ) = abi.decode(payload, (address[], uint256[], bytes[], bytes32));

        // Schedule on Polygon Timelock
        uint256 minDelay = TIMELOCK.getMinDelay();
        TIMELOCK.scheduleBatch(targets, values, calldatas, bytes32(0), salt, minDelay);

        emit CrossChainGovernanceReceived(sequence, targets, values, salt);
    }

    /**
     * @notice Cancel a scheduled batch operation on the Polygon Timelock
     * @dev Callable by owner or emergencyGuardian.
     *      If ownership is still held by an EOA or multisig, the owner path can cancel immediately.
     *      After ownership is transferred to the Polygon Timelock, calls through the owner path are
     *      themselves timelock-controlled and therefore are not a fast-cancel mechanism; in that
     *      deployment model, only emergencyGuardian provides immediate cancellation.
     *      Requires this contract to have CANCELLER_ROLE on the Timelock.
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
     * @param _governanceSender Address of the GovernanceSender contract (bytes32, left-padded)
     */
    function setGovernanceSender(bytes32 _governanceSender) external onlyOwner {
        if (_governanceSender == bytes32(0)) revert InvalidSender();
        bytes32 old = governanceSender;
        governanceSender = _governanceSender;
        emit GovernanceSenderUpdated(old, _governanceSender);
    }

    /**
     * @notice Set or remove the emergency guardian address for fast cancellation
     * @param _guardian Address of the emergency guardian (e.g., multisig), or address(0) to disable
     */
    function setEmergencyGuardian(address _guardian) external onlyOwner {
        address old = emergencyGuardian;
        emergencyGuardian = _guardian;
        emit EmergencyGuardianUpdated(old, _guardian);
    }

    /**
     * @notice Withdraw ETH accidentally sent to this contract
     * @param to Recipient address
     * @param amount Amount of ETH to withdraw
     */
    function withdrawETH(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert WithdrawFailed();
        (bool success,) = to.call{value: amount}("");
        if (!success) revert WithdrawFailed();
    }
}
