// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IWormholeRelayer } from "./IWormholeInterfaces.sol";

/**
 * @title GovernanceSender
 * @notice Ethereum-side contract that sends governance proposals cross-chain via Wormhole
 * @dev Owned by the Ethereum TimelockController. Encodes batch operations and sends
 *      them to GovernanceReceiver on Polygon through Wormhole Automatic Relayer.
 *
 * Flow: Ethereum Governor → Timelock → GovernanceSender → Wormhole → GovernanceReceiver (Polygon)
 */
contract GovernanceSender is Ownable {
    /// @notice Wormhole chain ID for Polygon
    uint16 public constant TARGET_CHAIN = 5;

    /// @notice Wormhole Automatic Relayer contract
    IWormholeRelayer public immutable WORMHOLE_RELAYER;

    /// @notice Address of GovernanceReceiver on Polygon
    address public governanceReceiver;

    /// @notice Gas limit for cross-chain delivery on Polygon
    uint256 public gasLimit;

    event CrossChainGovernanceSent(
        uint64 indexed sequence,
        address[] targets,
        uint256[] values,
        bytes32 salt
    );
    event GovernanceReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    event GasLimitUpdated(uint256 oldGasLimit, uint256 newGasLimit);

    error InvalidReceiver();
    error InvalidGasLimit();
    error ArrayLengthMismatch();
    error EmptyProposal();
    error InsufficientFee(uint256 required, uint256 provided);
    error InvalidRelayer();
    error WithdrawFailed();

    /**
     * @param _wormholeRelayer Address of the Wormhole Automatic Relayer
     * @param _governanceReceiver Address of GovernanceReceiver on Polygon
     * @param _gasLimit Gas limit for delivery on Polygon
     * @param _owner Initial owner (typically the Ethereum Timelock, or a deployer EOA that later transfers ownership)
     */
    constructor(
        address _wormholeRelayer,
        address _governanceReceiver,
        uint256 _gasLimit,
        address _owner
    ) Ownable(_owner) {
        if (_wormholeRelayer == address(0) || _wormholeRelayer.code.length == 0) revert InvalidRelayer();
        if (_governanceReceiver == address(0)) revert InvalidReceiver();
        if (_gasLimit == 0) revert InvalidGasLimit();

        WORMHOLE_RELAYER = IWormholeRelayer(_wormholeRelayer);
        governanceReceiver = _governanceReceiver;
        gasLimit = _gasLimit;
    }

    /**
     * @notice Send a batch governance operation cross-chain to Polygon
     * @dev Pays the Wormhole delivery fee from the contract's ETH balance plus any
     *      msg.value sent with the call. This makes Timelock execution resilient to
     *      fee changes between proposal creation and execution — pre-fund this contract
     *      with ETH to absorb fee increases.
     * @param targets Target contract addresses on Polygon
     * @param values ETH values for each call (typically 0 on Polygon)
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

        (uint256 deliveryPrice,) = WORMHOLE_RELAYER.quoteEVMDeliveryPrice(TARGET_CHAIN, 0, gasLimit);
        uint256 available = address(this).balance;
        if (available < deliveryPrice) {
            revert InsufficientFee(deliveryPrice, available);
        }

        uint64 sequence = WORMHOLE_RELAYER.sendPayloadToEvm{ value: deliveryPrice }(
            TARGET_CHAIN,
            governanceReceiver,
            payload,
            0,
            gasLimit
        );

        emit CrossChainGovernanceSent(sequence, targets, values, salt);
    }

    /**
     * @notice Withdraw ETH from this contract (e.g., excess pre-funded relayer fees)
     * @param to Recipient address
     * @param amount Amount of ETH to withdraw
     */
    function withdrawETH(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert WithdrawFailed();
        (bool success,) = to.call{ value: amount }("");
        if (!success) revert WithdrawFailed();
    }

    /// @notice Allow this contract to receive ETH for pre-funding relayer fees
    receive() external payable {}

    /**
     * @notice Quote the delivery price for a cross-chain governance message
     * @return nativePriceQuote Amount of native currency (ETH) required
     */
    function quoteDeliveryPrice() external view returns (uint256 nativePriceQuote) {
        (nativePriceQuote,) = WORMHOLE_RELAYER.quoteEVMDeliveryPrice(TARGET_CHAIN, 0, gasLimit);
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
     * @notice Update the gas limit for cross-chain delivery
     * @param _gasLimit New gas limit
     */
    function setGasLimit(uint256 _gasLimit) external onlyOwner {
        if (_gasLimit == 0) revert InvalidGasLimit();
        uint256 old = gasLimit;
        gasLimit = _gasLimit;
        emit GasLimitUpdated(old, _gasLimit);
    }
}
