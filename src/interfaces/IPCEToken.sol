// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IPCEToken {
    function getSwapRate(address fromToken) external returns (uint256);
}
