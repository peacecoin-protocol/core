// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title IWormholeRelayer
 * @notice Minimal interface for Wormhole Automatic Relayer (sendPayloadToEvm)
 */
interface IWormholeRelayer {
    /**
     * @notice Send a payload to an EVM chain via Wormhole
     * @param targetChain Wormhole chain ID of the target chain
     * @param targetAddress Address of the receiver contract on the target chain
     * @param payload Arbitrary payload to deliver
     * @param receiverValue msg.value to pass to the receiver on the target chain
     * @param gasLimit Gas limit for the delivery transaction on the target chain
     * @return sequence The sequence number of the delivery request
     */
    function sendPayloadToEvm(
        uint16 targetChain,
        address targetAddress,
        bytes memory payload,
        uint256 receiverValue,
        uint256 gasLimit
    ) external payable returns (uint64 sequence);

    /**
     * @notice Quote the delivery price for a cross-chain message
     * @param targetChain Wormhole chain ID of the target chain
     * @param receiverValue msg.value to pass to the receiver
     * @param gasLimit Gas limit for the delivery transaction
     * @return nativePriceQuote The amount of native currency required
     * @return targetChainRefundPerGasUnused Refund per unused gas unit
     */
    function quoteEVMDeliveryPrice(
        uint16 targetChain,
        uint256 receiverValue,
        uint256 gasLimit
    ) external view returns (uint256 nativePriceQuote, uint256 targetChainRefundPerGasUnused);
}

/**
 * @title IWormholeReceiver
 * @notice Interface that must be implemented by contracts receiving Wormhole messages
 */
interface IWormholeReceiver {
    /**
     * @notice Called by the Wormhole Relayer to deliver a message
     * @param payload The payload sent from the source chain
     * @param additionalMessages Any additional VAAs requested (empty for simple relaying)
     * @param sourceAddress The sender address on the source chain (left-padded to bytes32)
     * @param sourceChain The Wormhole chain ID of the source chain
     * @param deliveryHash Unique hash identifying this delivery
     */
    function receiveWormholeMessages(
        bytes memory payload,
        bytes[] memory additionalMessages,
        bytes32 sourceAddress,
        uint16 sourceChain,
        bytes32 deliveryHash
    ) external payable;
}
