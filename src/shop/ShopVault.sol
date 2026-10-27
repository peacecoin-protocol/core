// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Per-shop receiving address. Deployed as an EIP-1167 clone by ShopVaultFactory via CREATE2.
/// Only the controller (the factory) can move funds; the factory enforces the withdraw policy.
contract ShopVault {
    using SafeERC20 for IERC20;

    address public token;
    bytes32 public shopId;
    address public controller;

    error AlreadyInitialized();
    error NotController();
    error NativeTransferFailed();

    event Withdrawn(address indexed asset, address indexed to, uint256 amount);

    function initialize(address token_, bytes32 shopId_, address controller_) external {
        if (controller != address(0)) revert AlreadyInitialized();
        token = token_;
        shopId = shopId_;
        controller = controller_;
    }

    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
        _;
    }

    receive() external payable { }

    function withdrawERC20(address erc20, address to, uint256 amount) external onlyController {
        IERC20(erc20).safeTransfer(to, amount);
        emit Withdrawn(erc20, to, amount);
    }

    function withdrawNative(address to, uint256 amount) external onlyController {
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert NativeTransferFailed();
        emit Withdrawn(address(0), to, amount);
    }
}
