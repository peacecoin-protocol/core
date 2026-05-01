// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ExchangeAllowMethod } from "./Enum.sol";
import { PCEToken } from "../PCEToken.sol";
import { Utils } from "./Utils.sol";

library TokenValueOps {
    function computeSwapAmount(
        address pceAddress,
        address fromCommunityToken,
        address toCommunityToken,
        uint256 amountToSwap,
        uint256 fromCurrentFactor,
        uint256 toCurrentFactor
    )
        public
        view
        returns (uint256 targetTokenAmount)
    {
        PCEToken pceToken = PCEToken(pceAddress);
        Utils.LocalToken memory fromToken = pceToken.getLocalToken(fromCommunityToken);
        require(fromToken.isExists, "From token not found");
        Utils.LocalToken memory toToken = pceToken.getLocalToken(toCommunityToken);
        require(toToken.isExists, "Target token not found");

        uint256 pceCurrent = pceToken.getCurrentFactor();
        targetTokenAmount = Math.mulDiv(
            Math.mulDiv(
                Math.mulDiv(amountToSwap, 10 ** 18, fromToken.exchangeRate),
                pceCurrent,
                fromCurrentFactor
            ),
            Math.mulDiv(toToken.exchangeRate, toCurrentFactor, 10 ** 18),
            pceCurrent
        );
        require(targetTokenAmount > 0, "Invalid amount to swap");
    }

    function isAllowExchange(
        bool isIncome,
        address tokenAddress,
        ExchangeAllowMethod incomeAllow,
        ExchangeAllowMethod outgoAllow,
        address[] memory incomeTargets,
        address[] memory outgoTargets
    )
        public
        pure
        returns (bool)
    {
        ExchangeAllowMethod allowMethod = isIncome ? incomeAllow : outgoAllow;
        address[] memory targetTokens = isIncome ? incomeTargets : outgoTargets;
        if (allowMethod == ExchangeAllowMethod.None) return false;
        if (allowMethod == ExchangeAllowMethod.All) return true;
        if (allowMethod == ExchangeAllowMethod.Include) {
            for (uint256 i = 0; i < targetTokens.length;) {
                if (targetTokens[i] == tokenAddress) return true;
                unchecked { i++; }
            }
            return false;
        } else if (allowMethod == ExchangeAllowMethod.Exclude) {
            for (uint256 i = 0; i < targetTokens.length;) {
                if (targetTokens[i] == tokenAddress) return false;
                unchecked { i++; }
            }
            return true;
        }
        revert("Invalid exchangeAllowMethod");
    }
}
