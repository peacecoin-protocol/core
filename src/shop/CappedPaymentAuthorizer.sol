// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @notice Design sketch for barcode (store-scan) payments: the customer signs a capped, short-lived,
/// single-use authorization; the store submits it with the actual amount (<= maxAmount) to a shop vault.
/// This sketch pulls funds with ERC20 transferFrom and needs a prior approval to this contract.
/// The real version needs a PCECommunityToken upgrade that verifies this authorization natively
/// (no approval, demurrage-aware amounts, daily/monthly limits enforced on-chain).
contract CappedPaymentAuthorizer is EIP712 {
    using SafeERC20 for IERC20;

    bytes32 public constant CAPPED_PAYMENT_TYPEHASH =
        keccak256("CappedPayment(address token,address from,uint256 maxAmount,uint256 validBefore,bytes32 nonce)");

    mapping(address from => mapping(bytes32 nonce => bool)) public nonceUsed;

    error Expired();
    error OverCap();
    error NonceUsed();
    error InvalidSignature();

    event CappedPaymentExecuted(
        address indexed token, address indexed from, address indexed to, uint256 amount, bytes32 nonce
    );

    constructor() EIP712("CappedPaymentAuthorizer", "1") { }

    function hashAuthorization(
        address token,
        address from,
        uint256 maxAmount,
        uint256 validBefore,
        bytes32 nonce
    )
        public
        view
        returns (bytes32)
    {
        return
            _hashTypedDataV4(keccak256(abi.encode(CAPPED_PAYMENT_TYPEHASH, token, from, maxAmount, validBefore, nonce)));
    }

    /// @dev `to` should be a ShopVault address (predict()); restricting the submitter/recipient is left to the real
    /// version.
    function pay(
        address token,
        address from,
        uint256 maxAmount,
        uint256 validBefore,
        bytes32 nonce,
        address to,
        uint256 amount,
        bytes calldata signature
    )
        external
    {
        if (block.timestamp >= validBefore) revert Expired();
        if (amount > maxAmount) revert OverCap();
        if (nonceUsed[from][nonce]) revert NonceUsed();
        bytes32 digest = hashAuthorization(token, from, maxAmount, validBefore, nonce);
        if (!SignatureChecker.isValidSignatureNow(from, digest, signature)) revert InvalidSignature();
        nonceUsed[from][nonce] = true;
        IERC20(token).safeTransferFrom(from, to, amount);
        emit CappedPaymentExecuted(token, from, to, amount, nonce);
    }
}
