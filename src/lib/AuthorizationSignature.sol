// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @notice Signature check shared by the `bytes` signature authorization functions.
library AuthorizationSignature {
    /// @dev Accepts a 65-byte ECDSA signature by `signer` first, so EOAs (including EIP-7702
    /// delegated EOAs that have code) keep working. Otherwise, a signer with code is asked via
    /// ERC-1271. `isValidSignature` is reached through `staticcall` and cannot change state.
    function isValid(address signer, bytes32 digest, bytes memory signature) internal view returns (bool) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == signer) {
            return true;
        }
        if (signer.code.length == 0) {
            return false;
        }
        return SignatureChecker.isValidERC1271SignatureNow(signer, digest, signature);
    }
}
