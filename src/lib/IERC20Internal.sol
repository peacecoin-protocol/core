// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

abstract contract IERC20Internal {
    function _transfer(address sender, address recipient, uint256 amount) internal virtual;
}
