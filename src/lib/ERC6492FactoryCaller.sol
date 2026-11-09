// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Calls the factory named in an ERC-6492 signature, on behalf of a token.
/// @dev The factory and its calldata come from the signature wrapper and are not bound by the
/// signature, so anyone can choose them. Calling them from the token itself would let the factory
/// act as the token (for example, a token's self-only or PCEToken's community-token-only
/// functions). This contract is stateless and must never be granted a role, allowance or balance.
contract ERC6492FactoryCaller {
    function callFactory(address factory, bytes calldata factoryCalldata) external {
        (bool success,) = factory.call(factoryCalldata);
        // The caller decides by checking whether the signer has code afterwards.
        success;
    }
}
