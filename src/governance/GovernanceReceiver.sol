// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IWormholeReceiver } from "./IWormholeInterfaces.sol";

/**
 * @title GovernanceReceiver
 * @notice Polygon-side contract that receives governance proposals from Ethereum via Wormhole
 * @dev Receives cross-chain messages from GovernanceSender and schedules them on a
 *      local TimelockController for delayed execution.
 *
 * Flow: GovernanceSender (Ethereum) → Wormhole → GovernanceReceiver → Polygon Timelock → PCEToken
 */
contract GovernanceReceiver is IWormholeReceiver, Ownable {
    /// @notice Wormhole chain ID for Ethereum
    uint16 public constant SOURCE_CHAIN = 2;

    /// @notice Wormhole Relayer contract on Polygon
    address public immutable WORMHOLE_RELAYER;

    /// @notice Polygon TimelockController for delayed execution
    TimelockController public immutable TIMELOCK;

    /// @notice Address of GovernanceSender on Ethereum
    address public governanceSender;

    /// @notice Emergency guardian that can cancel scheduled operations without timelock delay
    address public emergencyGuardian;

    /// @notice Tracks processed delivery hashes to prevent replay
    mapping(bytes32 deliveryHash => bool processed) public processedDeliveries;

    event CrossChainGovernanceReceived(
        bytes32 indexed deliveryHash,
        address[] targets,
        uint256[] values,
        bytes32 salt
    );
    event GovernanceSenderUpdated(address indexed oldSender, address indexed newSender);
    event EmergencyGuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    error UnauthorizedRelayer(address caller);
    error InvalidSourceChain(uint16 sourceChain);
    error InvalidSourceAddress(bytes32 sourceAddress);
    error DeliveryAlreadyProcessed(bytes32 deliveryHash);
    error InvalidSender();
    error InvalidRelayer();
    error InvalidTimelock();
    error GovernanceSenderNotSet();
    error NotOwnerOrGuardian();
    error WithdrawFailed();

    /**
     * @param _wormholeRelayer Address of the Wormhole Relayer on Polygon
     * @param _timelock Address of the Polygon TimelockController
     * @param _owner Initial owner (deployer)
     */
    constructor(
        address _wormholeRelayer,
        address _timelock,
        address _owner
    ) Ownable(_owner) {
        if (_wormholeRelayer == address(0) || _wormholeRelayer.code.length == 0) revert InvalidRelayer();
        if (_timelock == address(0) || _timelock.code.length == 0) revert InvalidTimelock();

        WORMHOLE_RELAYER = _wormholeRelayer;
        TIMELOCK = TimelockController(payable(_timelock));
    }

    /**
     * @notice Called by the Wormhole Relayer to deliver a cross-chain governance message
     * @param payload Encoded governance batch (targets, values, calldatas, salt)
     * @param sourceAddress The sender address on Ethereum (GovernanceSender, left-padded)
     * @param sourceChain The Wormhole chain ID of the source chain (must be 2 = Ethereum)
     * @param deliveryHash Unique hash for replay protection
     */
    function receiveWormholeMessages(
        bytes memory payload,
        bytes[] memory,
        bytes32 sourceAddress,
        uint16 sourceChain,
        bytes32 deliveryHash
    ) external payable override {
        // Verify caller is the Wormhole Relayer
        if (msg.sender != WORMHOLE_RELAYER) {
            revert UnauthorizedRelayer(msg.sender);
        }

        // Verify source chain is Ethereum
        if (sourceChain != SOURCE_CHAIN) {
            revert InvalidSourceChain(sourceChain);
        }

        // Verify GovernanceSender has been configured
        if (governanceSender == address(0)) {
            revert GovernanceSenderNotSet();
        }

        // Verify source address is GovernanceSender
        if (sourceAddress != _toBytes32(governanceSender)) {
            revert InvalidSourceAddress(sourceAddress);
        }

        // Prevent replay
        if (processedDeliveries[deliveryHash]) {
            revert DeliveryAlreadyProcessed(deliveryHash);
        }
        processedDeliveries[deliveryHash] = true;

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

        emit CrossChainGovernanceReceived(deliveryHash, targets, values, salt);
    }

    /**
     * @notice Cancel a scheduled batch operation on the Polygon Timelock
     * @dev Callable by owner OR emergencyGuardian for fast cancellation without timelock delay.
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
     * @param _governanceSender Address of the GovernanceSender contract
     */
    function setGovernanceSender(address _governanceSender) external onlyOwner {
        if (_governanceSender == address(0)) revert InvalidSender();
        address old = governanceSender;
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
        (bool success,) = to.call{ value: amount }("");
        if (!success) revert WithdrawFailed();
    }

    /**
     * @notice Convert an address to bytes32 (left-padded with zeros)
     */
    function _toBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }
}
