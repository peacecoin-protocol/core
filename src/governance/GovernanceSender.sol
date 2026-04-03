// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ExecutorSendQuoteOnChain} from "wormhole-solidity-sdk/Executor/Integration.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CONSISTENCY_LEVEL_FINALIZED} from "wormhole-solidity-sdk/constants/ConsistencyLevel.sol";
import {CHAIN_ID_POLYGON} from "wormhole-solidity-sdk/constants/Chains.sol";
import {toUniversalAddress} from "wormhole-solidity-sdk/Utils.sol";
import {RelayInstructionLib} from "wormhole-solidity-sdk/Executor/RelayInstruction.sol";
import {RequestLib} from "wormhole-solidity-sdk/Executor/Request.sol";

/**
 * @title GovernanceSender
 * @notice Ethereum-side contract that sends governance proposals cross-chain via Wormhole Executor
 * @dev Owned by the Ethereum TimelockController. Encodes batch operations and sends
 *      them to GovernanceReceiver on Polygon through the Wormhole Executor Framework.
 *
 * Flow: Ethereum Governor → Timelock → GovernanceSender → Wormhole Executor → GovernanceReceiver (Polygon)
 */
contract GovernanceSender is ExecutorSendQuoteOnChain, Ownable {
    /// @notice Wormhole chain ID for Polygon
    uint16 public constant TARGET_CHAIN = CHAIN_ID_POLYGON;

    /// @notice Address of GovernanceReceiver on Polygon (stored as bytes32)
    bytes32 public governanceReceiver;

    /// @notice Gas limit for cross-chain delivery on Polygon
    uint128 public gasLimit;

    /// @notice On-chain quoter address for fee estimation
    address public quoterAddress;

    event CrossChainGovernanceSent(
        uint64 indexed sequence,
        address[] targets,
        uint256[] values,
        bytes32 salt
    );
    event GovernanceReceiverUpdated(bytes32 indexed oldReceiver, bytes32 indexed newReceiver);
    event GasLimitUpdated(uint128 oldGasLimit, uint128 newGasLimit);
    event QuoterAddressUpdated(address indexed oldQuoter, address indexed newQuoter);

    error InvalidReceiver();
    error InvalidGasLimit();
    error ArrayLengthMismatch();
    error EmptyProposal();
    error InsufficientFee(uint256 required, uint256 provided);
    error WithdrawFailed();
    error InvalidQuoter();

    /**
     * @param _coreBridge Address of the Wormhole Core Bridge on Ethereum
     * @param _executorQuoterRouter Address of the Wormhole ExecutorQuoterRouter on Ethereum
     * @param _governanceReceiver Address of GovernanceReceiver on Polygon (bytes32, left-padded)
     * @param _gasLimit Gas limit for delivery on Polygon
     * @param _quoterAddress Address of the on-chain quoter
     * @param _owner Initial owner (typically the Ethereum Timelock, or a deployer EOA that later transfers ownership)
     */
    constructor(
        address _coreBridge,
        address _executorQuoterRouter,
        bytes32 _governanceReceiver,
        uint128 _gasLimit,
        address _quoterAddress,
        address _owner
    ) ExecutorSendQuoteOnChain(_coreBridge, _executorQuoterRouter) Ownable(_owner) {
        if (_governanceReceiver == bytes32(0)) revert InvalidReceiver();
        if (_gasLimit == 0) revert InvalidGasLimit();
        if (_quoterAddress == address(0) || _quoterAddress.code.length == 0) revert InvalidQuoter();

        governanceReceiver = _governanceReceiver;
        gasLimit = _gasLimit;
        quoterAddress = _quoterAddress;
    }

    /// @dev Required by ExecutorSharedBase — returns peer address for target chain
    function _getPeer(uint16 chainId) internal view override returns (bytes32) {
        if (chainId == TARGET_CHAIN) return governanceReceiver;
        return bytes32(0);
    }

    /**
     * @notice Send a batch governance operation cross-chain to Polygon
     * @dev Pays fees from contract balance + msg.value. Pre-fund this contract
     *      with ETH to absorb fee fluctuations between proposal creation and execution.
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

        bytes memory payload = abi.encode(targets, values, calldatas, salt);

        uint256 totalCost = quoteDeliveryPrice();
        if (address(this).balance < totalCost) {
            revert InsufficientFee(totalCost, address(this).balance);
        }

        uint64 sequence = _publishAndRelay(
            payload,
            CONSISTENCY_LEVEL_FINALIZED,
            totalCost,
            TARGET_CHAIN,
            address(this), // refund to this contract
            quoterAddress,
            gasLimit,
            0, // no msg.value on destination
            "" // no extra relay instructions
        );

        emit CrossChainGovernanceSent(sequence, targets, values, salt);
    }

    /**
     * @notice Quote the delivery price for a cross-chain governance message
     * @return totalCost Amount of ETH required (executor fee + core bridge message fee)
     */
    function quoteDeliveryPrice() public view returns (uint256 totalCost) {
        bytes memory relayInstructions = RelayInstructionLib.encodeGas(gasLimit, 0);
        bytes memory requestBytes = RequestLib.encodeVaaMultiSigRequest(
            _chainId, toUniversalAddress(address(this)), 0
        );

        uint256 executorFee = _executorQuoterRouter.quoteExecution(
            TARGET_CHAIN, governanceReceiver, address(this), quoterAddress, requestBytes, relayInstructions
        );

        totalCost = executorFee + _coreBridge.messageFee();
    }

    /**
     * @notice Update the GovernanceReceiver address on Polygon
     * @param _governanceReceiver New receiver address (bytes32, left-padded)
     */
    function setGovernanceReceiver(bytes32 _governanceReceiver) external onlyOwner {
        if (_governanceReceiver == bytes32(0)) revert InvalidReceiver();
        bytes32 old = governanceReceiver;
        governanceReceiver = _governanceReceiver;
        emit GovernanceReceiverUpdated(old, _governanceReceiver);
    }

    /**
     * @notice Update the gas limit for cross-chain delivery
     * @param _gasLimit New gas limit
     */
    function setGasLimit(uint128 _gasLimit) external onlyOwner {
        if (_gasLimit == 0) revert InvalidGasLimit();
        uint128 old = gasLimit;
        gasLimit = _gasLimit;
        emit GasLimitUpdated(old, _gasLimit);
    }

    /**
     * @notice Update the on-chain quoter address
     * @param _quoterAddress New quoter address
     */
    function setQuoterAddress(address _quoterAddress) external onlyOwner {
        if (_quoterAddress == address(0) || _quoterAddress.code.length == 0) revert InvalidQuoter();
        address old = quoterAddress;
        quoterAddress = _quoterAddress;
        emit QuoterAddressUpdated(old, _quoterAddress);
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

    /// @notice Allow this contract to receive ETH for pre-funding relay fees
    receive() external payable {}
}
