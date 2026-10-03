// SPDX-License-Identifier: GPL
pragma solidity 0.8.30;

/// @notice Sender resolution for Polygon native meta-transactions.
/// @dev Only a verified NativeMetaTransaction self-call may supply the suffix.
/// Never combine this context with Multicall or another self-delegatecall path.
abstract contract ContextMixin {
    error InvalidMetaTransactionContext();

    function msgSender() internal view returns (address sender) {
        if (msg.sender != address(this)) {
            return msg.sender;
        }

        if (msg.data.length < 20) {
            revert InvalidMetaTransactionContext();
        }

        assembly ("memory-safe") {
            sender := shr(96, calldataload(sub(calldatasize(), 20)))
        }
    }
}
