// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ExchangeAllowMethod } from "./Enum.sol";
import { PCEToken } from "../PCEToken.sol";
import { Utils } from "./Utils.sol";

library TokenValueOps {
    event TreasuryWalletSet(address indexed wallet);
    event TokenValueIncreased(uint256 pceAmount, uint256 oldExchangeRate, uint256 newExchangeRate);
    event TokenSplit(
        uint256 mintAmount,
        uint256 oldExchangeRate,
        uint256 newExchangeRate,
        uint256 oldRebaseFactor,
        uint256 newRebaseFactor
    );
    event RateManagerRoleGranted(address indexed account);
    event RateManagerRoleRevoked(address indexed account);

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

    function initializeTreasury(
        address currentTreasury,
        address wallet,
        address sender,
        mapping(bytes32 => mapping(address => bool)) storage roles,
        bytes32 role
    )
        public
        returns (address newTreasury, uint256 newRebaseFactor)
    {
        require(currentTreasury == address(0), "Already initialized");
        require(wallet != address(0), "Invalid wallet address");
        roles[role][sender] = true;
        emit TreasuryWalletSet(wallet);
        emit RateManagerRoleGranted(sender);
        return (wallet, 10 ** 18);
    }

    function setTreasuryWallet(address wallet) public returns (address) {
        require(wallet != address(0), "Invalid wallet address");
        emit TreasuryWalletSet(wallet);
        return wallet;
    }

    function increaseTokenValue(
        uint256 pceAmount,
        address pceAddress,
        address self,
        address treasuryWallet
    )
        public
    {
        require(pceAmount > 0, "Amount must be > 0");
        PCEToken pceToken = PCEToken(pceAddress);
        uint256 oldExchangeRate = pceToken.getExchangeRate(self);
        pceToken.addReserve(self, pceAmount, treasuryWallet);
        uint256 newExchangeRate = pceToken.getExchangeRate(self);
        emit TokenValueIncreased(pceAmount, oldExchangeRate, newExchangeRate);
    }

    function splitToken(
        uint256 mintAmount,
        uint256 currentTotalDisplay,
        uint256 oldRebaseFactor,
        address pceAddress,
        address self
    )
        public
        returns (uint256 newRebaseFactor)
    {
        require(mintAmount > 0, "Amount must be > 0");
        require(currentTotalDisplay > 0, "No supply to split");

        PCEToken pceToken = PCEToken(pceAddress);
        uint256 oldExchangeRate = pceToken.getExchangeRate(self);

        newRebaseFactor = Math.mulDiv(oldRebaseFactor, currentTotalDisplay + mintAmount, currentTotalDisplay);

        uint256 newRate = Math.mulDiv(oldExchangeRate, newRebaseFactor, oldRebaseFactor);
        pceToken.adjustExchangeRate(self, newRate);

        uint256 newExchangeRate = pceToken.getExchangeRate(self);
        emit TokenSplit(mintAmount, oldExchangeRate, newExchangeRate, oldRebaseFactor, newRebaseFactor);
    }

    function grantRateManagerRole(
        address account,
        mapping(bytes32 => mapping(address => bool)) storage roles,
        bytes32 role
    )
        public
    {
        require(account != address(0), "Invalid account address");
        roles[role][account] = true;
        emit RateManagerRoleGranted(account);
    }

    function revokeRateManagerRole(
        address account,
        mapping(bytes32 => mapping(address => bool)) storage roles,
        bytes32 role
    )
        public
    {
        require(account != address(0), "Invalid account address");
        roles[role][account] = false;
        emit RateManagerRoleRevoked(account);
    }
}
