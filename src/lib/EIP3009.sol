// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { EIP712Domain } from "./EIP712Domain.sol";
import { EIP712 } from "./EIP712.sol";

abstract contract EIP3009 is ERC20Upgradeable, EIP712Domain {
    /*
        keccak256(
            "TransferWithAuthorization(address from,address to,
                uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
        )
    */
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH =
        0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267;

    mapping(address authorizer => mapping(bytes32 nonce => bool isUsed)) internal _authorizationStates;

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    error NotYetValid();
    error AuthorizationExpired();
    error AuthorizationAlreadyUsed();
    error EIP3009InvalidSignature();

    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool) {
        return _authorizationStates[authorizer][nonce];
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        public
        virtual;

    function _transferWithAuthorization(
        address from,
        address to,
        uint256 value,
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
        if (block.timestamp <= validAfter) revert NotYetValid();
        if (block.timestamp >= validBefore) revert AuthorizationExpired();
        if (_authorizationStates[from][nonce]) revert AuthorizationAlreadyUsed();

        bytes memory data =
            abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce);
        if (EIP712.recover(EIP712.makeDomainSeparator("PeaceBaseCoin", "1"), v, r, s, data) != from) {
            revert EIP3009InvalidSignature();
        }

        _authorizationStates[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);

        _transfer(from, to, rawAmount);
    }
}
