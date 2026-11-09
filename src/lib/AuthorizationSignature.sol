// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { Bytes } from "@openzeppelin/contracts/utils/Bytes.sol";
import { ERC6492FactoryCaller } from "./ERC6492FactoryCaller.sol";

/// @notice Signature check shared by the `bytes` signature authorization functions.
library AuthorizationSignature {
    /// @dev ERC-6492 wrapper suffix.
    bytes32 internal constant ERC6492_DETECTION_SUFFIX =
        0x6492649264926492649264926492649264926492649264926492649264926492;

    /// @dev Accepts, in order:
    /// - an ERC-6492 wrapper `abi.encode(factory, factoryCalldata, signature) || suffix`: if the
    ///   signer has no code, the factory is called through an `ERC6492FactoryCaller` and the
    ///   signer must have code afterwards; the inner signature is then checked with ERC-1271 only.
    /// - a 65-byte ECDSA signature by `signer`, so EOAs (including EIP-7702 delegated EOAs that
    ///   have code) keep working.
    /// - an ERC-1271 signature from a signer with code.
    /// `isValidSignature` is reached through `staticcall`. The factory call can run arbitrary code,
    /// so callers must consume the nonce before this check, be non-reentrant, and read balances,
    /// factors and fees only after it.
    function isValid(address signer, bytes32 digest, bytes memory signature) internal returns (bool) {
        uint256 length = signature.length;
        if (length >= 32 && bytes32(Bytes.slice(signature, length - 32)) == ERC6492_DETECTION_SUFFIX) {
            (address factory, bytes memory factoryCalldata, bytes memory innerSignature) =
                abi.decode(Bytes.slice(signature, 0, length - 32), (address, bytes, bytes));
            if (signer.code.length == 0) {
                _factoryCaller().callFactory(factory, factoryCalldata);
                if (signer.code.length == 0) {
                    return false;
                }
            }
            return SignatureChecker.isValidERC1271SignatureNow(signer, digest, innerSignature);
        }

        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == signer) {
            return true;
        }
        if (signer.code.length == 0) {
            return false;
        }
        return SignatureChecker.isValidERC1271SignatureNow(signer, digest, signature);
    }

    /// @dev The calling contract's own `ERC6492FactoryCaller`, created with CREATE2 on first use.
    function _factoryCaller() private returns (ERC6492FactoryCaller caller) {
        bytes32 initCodeHash = keccak256(type(ERC6492FactoryCaller).creationCode);
        caller = ERC6492FactoryCaller(
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(0), initCodeHash))))
            )
        );
        if (address(caller).code.length == 0) {
            caller = new ERC6492FactoryCaller{ salt: bytes32(0) }();
        }
    }
}
