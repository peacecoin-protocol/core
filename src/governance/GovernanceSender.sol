// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IWormhole {
    function publishMessage(uint32 nonce, bytes memory payload, uint8 consistencyLevel)
        external payable returns (uint64 sequence);
    function messageFee() external view returns (uint256);
}

/**
 * @title GovernanceSender
 * @notice Ethereum-side contract that sends governance proposals cross-chain via Wormhole Core Bridge
 * @dev Owned by the Ethereum TimelockController. Publishes governance payloads as Wormhole messages.
 *      VAAs are then relayed to GovernanceReceiver on Polygon by anyone (permissionless relay).
 *
 * Flow: Ethereum Governor → Timelock → GovernanceSender → Wormhole Core Bridge
 *       → Guardian signatures → VAA → anyone relays → GovernanceReceiver (Polygon)
 */
contract GovernanceSender is Ownable {
    /// @notice Wormhole Core Bridge contract
    IWormhole public immutable WORMHOLE;

    /// @notice Wormhole chain ID for Polygon
    uint16 public constant TARGET_CHAIN = 5;

    /// @notice Consistency level: 1 = finalized on Ethereum
    uint8 public constant CONSISTENCY_LEVEL = 1;

    /// @notice Address of GovernanceReceiver on Polygon
    address public governanceReceiver;

    event CrossChainGovernanceSent(
        uint64 indexed sequence,
        address[] targets,
        uint256[] values,
        bytes32 salt
    );
    event GovernanceReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);

    error InvalidReceiver();
    error InvalidWormhole();
    error InsufficientFee(uint256 required, uint256 provided);
    error ArrayLengthMismatch();
    error EmptyProposal();
    error WithdrawFailed();

    /**
     * @param _wormhole Address of the Wormhole Core Bridge on Ethereum
     * @param _governanceReceiver Address of GovernanceReceiver on Polygon
     * @param _owner Initial owner (typically the Ethereum Timelock)
     */
    constructor(
        address _wormhole,
        address _governanceReceiver,
        address _owner
    ) Ownable(_owner) {
        if (_wormhole == address(0) || _wormhole.code.length == 0) revert InvalidWormhole();
        if (_governanceReceiver == address(0)) revert InvalidReceiver();

        WORMHOLE = IWormhole(_wormhole);
        governanceReceiver = _governanceReceiver;
    }

    /**
     * @notice Send a batch governance operation cross-chain to Polygon
     * @dev Pays Wormhole message fee from contract balance + msg.value.
     *      The published message becomes a VAA that anyone can relay to the Receiver.
     * @param targets Target contract addresses on Polygon
     * @param values Native token values for each call (typically 0 on Polygon)
     * @param calldatas Encoded function calls
     * @param salt Unique salt for TimelockController scheduling
     */
    function sendCrossChainGovernance(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 salt
    ) external payable onlyOwner {
        if (targets.length == 0) revert EmptyProposal();
        if (targets.length != values.length || targets.length != calldatas.length) {
            revert ArrayLengthMismatch();
        }

        uint256 messageFee = WORMHOLE.messageFee();
        if (address(this).balance < messageFee) {
            revert InsufficientFee(messageFee, address(this).balance);
        }

        bytes memory payload = abi.encode(targets, values, calldatas, salt, governanceReceiver, TARGET_CHAIN);

        uint64 sequence = WORMHOLE.publishMessage{value: messageFee}(0, payload, CONSISTENCY_LEVEL);

        emit CrossChainGovernanceSent(sequence, targets, values, salt);
    }

    /**
     * @notice Quote the Wormhole message fee
     * @return messageFee Amount of ETH required
     */
    function quoteDeliveryPrice() external view returns (uint256 messageFee) {
        return WORMHOLE.messageFee();
    }

    /**
     * @notice Update the GovernanceReceiver address on Polygon
     * @param _governanceReceiver New receiver address
     */
    function setGovernanceReceiver(address _governanceReceiver) external onlyOwner {
        if (_governanceReceiver == address(0)) revert InvalidReceiver();
        address old = governanceReceiver;
        governanceReceiver = _governanceReceiver;
        emit GovernanceReceiverUpdated(old, _governanceReceiver);
    }

    /**
     * @notice Withdraw ETH from this contract
     * @param to Recipient address
     * @param amount Amount of ETH to withdraw
     */
    function withdrawETH(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert WithdrawFailed();
        (bool success,) = to.call{value: amount}("");
        if (!success) revert WithdrawFailed();
    }

    /// @notice Allow this contract to receive ETH for pre-funding message fees
    receive() external payable {}
}
