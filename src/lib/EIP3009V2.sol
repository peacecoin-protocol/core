// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { EIP712 } from "./EIP712.sol";
import { EIP3009 } from "./EIP3009.sol";

abstract contract EIP3009V2 is EIP3009 {

    /*
        keccak256(
            "ApproveWithAuthorization(address owner,address spender,
                uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
        )
    */
    bytes32 public constant APPROVE_WITH_AUTHORIZATION_TYPEHASH =
        0x808c10407a796f3ef2c7ea38c0638ea9d2b8a1c63e3ca9e1f56ce84ae59df73c;


    // external function approveWithAuthorization
    function _approveWithAuthorization(
        address owner,
        address spender,
        uint256 displayBalance,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s,
        uint256 rawAmount
    )
        internal
    {
        require(block.timestamp > validAfter, "Not yet valid");
        require(block.timestamp < validBefore, "Authorization expired");
        require(!_authorizationStates[owner][nonce], "Authorization used");

        bytes memory data =
            abi.encode(APPROVE_WITH_AUTHORIZATION_TYPEHASH, owner, spender, displayBalance, validAfter, validBefore, nonce);
        require(
            EIP712.recover(EIP712.makeDomainSeparator("PeaceBaseCoin", "1"), v, r, s, data) == owner,
            "ApproveWithAuthorization: invalid signature"
        );

        _authorizationStates[owner][nonce] = true;
        emit AuthorizationUsed(owner, nonce);

        _approve(owner, spender, rawAmount);
    }
}
