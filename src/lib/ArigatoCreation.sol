// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ArigatoCreation
/// @notice Library encapsulating the Arigato Creation mint calculation to
///         reduce PCECommunityToken bytecode.
library ArigatoCreation {
    uint16 internal constant BP_BASE = 10_000;
    uint16 internal constant MAX_CHARACTER_LENGTH = 10;

    struct AccountInfo {
        uint256 midnightBalance;
        uint256 firstTransactionTime;
        uint256 lastModifiedMidnightBalanceTime;
        uint256 mintArigatoCreationToday;
    }

    struct Params {
        uint256 midnightTotalSupply;
        uint16 maxIncreaseOfTotalSupplyBp;
        uint16 maxIncreaseBp;
        uint16 maxUsageBp;
        uint16 changeBp;
        uint256 mintArigatoCreationToday;
        uint256 mintArigatoCreationTodayForGuest;
        uint256 rawAmount;
        uint256 rawBalance;
        uint256 messageCharacters;
    }

    /// @notice Compute the Arigato Creation mint amount and updated counters.
    ///         Returns `mintAmount = 0` when the caller should skip minting.
    function compute(
        AccountInfo memory accountInfo,
        Params memory p
    )
        public
        pure
        returns (
            uint256 mintAmount,
            bool isGuest
        )
    {
        uint256 maxArigatoCreationMintToday = Math.mulDiv(p.midnightTotalSupply, p.maxIncreaseOfTotalSupplyBp, BP_BASE);
        if (maxArigatoCreationMintToday == 0 || maxArigatoCreationMintToday <= p.mintArigatoCreationToday) {
            return (0, false);
        }
        uint256 remainingToday = maxArigatoCreationMintToday - p.mintArigatoCreationToday;
        uint256 remainingTodayForGuest;

        isGuest = accountInfo.firstTransactionTime == accountInfo.lastModifiedMidnightBalanceTime;
        if (isGuest) {
            uint256 maxForGuest = Math.mulDiv(maxArigatoCreationMintToday, 1, 10);
            if (maxForGuest == 0 || maxForGuest <= p.mintArigatoCreationTodayForGuest) {
                return (0, isGuest);
            }
            remainingTodayForGuest = maxForGuest - p.mintArigatoCreationTodayForGuest;
        }

        uint256 usageBp = Math.mulDiv(p.rawAmount, BP_BASE, p.rawBalance);
        uint256 absUsageBp = usageBp > p.maxUsageBp ? usageBp - p.maxUsageBp : uint256(p.maxUsageBp) - usageBp;
        uint256 changeMulBp = Math.mulDiv(uint256(p.changeBp), absUsageBp, BP_BASE);
        if (changeMulBp >= p.maxIncreaseBp) {
            return (0, isGuest);
        }
        uint256 messageLength = p.messageCharacters > 0 ? p.messageCharacters : 1;
        uint256 messageBp =
            messageLength > MAX_CHARACTER_LENGTH ? BP_BASE : Math.mulDiv(messageLength, BP_BASE, MAX_CHARACTER_LENGTH);
        uint256 increaseBp = uint256(p.maxIncreaseBp) - Math.mulDiv(changeMulBp, messageBp, BP_BASE);
        mintAmount = Math.mulDiv(p.rawAmount, increaseBp, BP_BASE);
        if (mintAmount > remainingToday) {
            mintAmount = remainingToday;
        }

        uint256 actualMinted =
            accountInfo.mintArigatoCreationToday > 0 ? accountInfo.mintArigatoCreationToday - 1 : 0;

        if (!isGuest) {
            uint256 maxForSender = Math.mulDiv(maxArigatoCreationMintToday, accountInfo.midnightBalance, p.midnightTotalSupply);
            if (maxForSender == 0) return (0, isGuest);
            uint256 remainingSender = maxForSender > actualMinted ? maxForSender - actualMinted : 0;
            if (remainingSender == 0) return (0, isGuest);
            if (mintAmount > remainingSender) mintAmount = remainingSender;
        } else {
            if (mintAmount > remainingTodayForGuest) mintAmount = remainingTodayForGuest;
            uint256 maxGuestSender = Math.mulDiv(maxArigatoCreationMintToday, 1, 100);
            if (maxGuestSender == 0) return (0, isGuest);
            uint256 remainingGuestSender = maxGuestSender > actualMinted ? maxGuestSender - actualMinted : 0;
            if (remainingGuestSender == 0) return (0, isGuest);
            if (mintAmount > remainingGuestSender) mintAmount = remainingGuestSender;
        }
    }
}
