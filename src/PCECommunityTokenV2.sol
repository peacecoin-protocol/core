// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ERC20BurnableUpgradeable } from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { ERC20PermitUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { PCEToken } from "./PCEToken.sol";
import { Utils } from "./lib/Utils.sol";
import { EIP3009V2 } from "./lib/EIP3009V2.sol";
import { TokenSetting } from "./lib/TokenSetting.sol";
import { ExchangeAllowMethod } from "./lib/Enum.sol";

import { console2 } from "forge-std/console2.sol";

/// @custom:oz-upgrades-from PCECommunityToken

contract PCECommunityTokenV2 is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    OwnableUpgradeable,
    EIP3009V2,
    ERC20PermitUpgradeable,
    TokenSetting
{
    uint256 public constant INITIAL_FACTOR = 10 ** 18;
    uint16 public constant BP_BASE = 10_000;
    uint16 public constant MAX_CHARACTER_LENGTH = 10;

    address public pceAddress;
    uint256 public initialFactor;
    uint256 public epochTime;
    uint256 public lastModifiedFactor;

    struct AccountInfo {
        uint256 midnightBalance;
        uint256 firstTransactionTime;
        uint256 lastModifiedMidnightBalanceTime;
        uint256 mintArigatoCreationToday;
    }

    mapping(address user => AccountInfo accountInfo) private _accountInfos;

    event PCETransfer(address indexed from, address indexed to, uint256 displayAmount, uint256 rawAmount);
    event MintArigatoCreation(address indexed to, uint256 displayAmount, uint256 rawAmount);
    event MetaTransactionFeeCollected(address indexed from, address indexed to, uint256 displayFee, uint256 rawFee);

    function initialize() public initializer { }

    function getCurrentFactor() public view returns (uint256) {
        if (lastModifiedFactor == 0) {
            return 0;
        }
        if (decreaseIntervalDays == 0) {
            return lastModifiedFactor;
        }
        if (intervalDaysOf(lastDecreaseTime, block.timestamp, decreaseIntervalDays)) {
            return lastModifiedFactor * afterDecreaseBp / BP_BASE;
        } else {
            return lastModifiedFactor;
        }
    }

    function updateFactorIfNeeded() public {
        if (lastDecreaseTime == block.timestamp) {
            return;
        }

        PCEToken pceToken = PCEToken(pceAddress);
        pceToken.updateFactorIfNeeded();

        uint256 currentFactor = getCurrentFactor();
        if (currentFactor != lastModifiedFactor) {
            lastModifiedFactor = currentFactor;
            lastDecreaseTime = block.timestamp;
        }
    }

    function rawBalanceToDisplayBalance(uint256 rawBalance) public view returns (uint256) {
        uint256 currentFactor = getCurrentFactor();
        if (currentFactor < 1) {
            currentFactor = 1;
        }
        return rawBalance / currentFactor;
    }

    function displayBalanceToRawBalance(uint256 displayBalance) public view returns (uint256) {
        uint256 currentFactor = getCurrentFactor();
        if (currentFactor < 1) {
            currentFactor = 1;
        }
        return displayBalance * currentFactor;
    }

    function totalSupply() public view override returns (uint256) {
        return rawBalanceToDisplayBalance(super.totalSupply());
    }

    function balanceOf(address account) public view override returns (uint256) {
        return rawBalanceToDisplayBalance(super.balanceOf(account));
    }

    function _update(address from, address to, uint256 value) internal override {
        _beforeTokenTransfer(from, to, value);
        super._update(from, to, value);
        _afterTokenTransfer(from, to, value);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal {
        if (midnightTotalSupplyModifiedTime == 0) {
            midnightTotalSupply = amount;
            midnightTotalSupplyModifiedTime = block.timestamp;
        } else if (intervalDaysOf(midnightTotalSupplyModifiedTime, block.timestamp, 1)) {
            midnightTotalSupply = super.totalSupply();
            midnightTotalSupplyModifiedTime = block.timestamp;
            // Reset arigatoCreateionMintToday, but set it to 1 instead of 0 to reduce gas consumption
            mintArigatoCreationToday = 1;
            mintArigatoCreationTodayForGuest = 1;
        }
        if (from != address(0)) {
            _beforeTokenTransferAtAddress(from);
        }
        if (to != address(0)) {
            _beforeTokenTransferAtAddress(to);
        }
    }

    function _beforeTokenTransferAtAddress(address account) internal {
        if (_accountInfos[account].firstTransactionTime == 0) {
            _accountInfos[account].firstTransactionTime = block.timestamp;
            _accountInfos[account].lastModifiedMidnightBalanceTime = block.timestamp;
            _accountInfos[account].midnightBalance = super.balanceOf(account);
        } else if (intervalDaysOf(_accountInfos[account].lastModifiedMidnightBalanceTime, block.timestamp, 1)) {
            _accountInfos[account].lastModifiedMidnightBalanceTime = block.timestamp;
            _accountInfos[account].midnightBalance = super.balanceOf(account);
            // Reset arigatoCreateionMintToday, but set it to 1 instead of 0 to reduce gas consumption
            _accountInfos[account].mintArigatoCreationToday = 1;
        }
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal {
        emit PCETransfer(from, to, rawBalanceToDisplayBalance(amount), amount);
    }

    function _mintArigatoCreation(
        address sender,
        uint256 rawAmount,
        uint256 rawBalance,
        uint256 messageCharacters
    )
        internal
    {
        // ** Global mint limit
        uint256 maxArigatoCreationMintToday = midnightTotalSupply * maxIncreaseOfTotalSupplyBp / BP_BASE;
        console2.log("maxtArigatoCreationToday: %s", maxArigatoCreationMintToday);
        console2.log("mintArigatoCreationToday: %s", mintArigatoCreationToday);
        if (maxArigatoCreationMintToday <= 0 || maxArigatoCreationMintToday <= mintArigatoCreationToday) {
            console2.log("return 167");
            return;
        }
        uint256 remainingArigatoCreationMintToday = maxArigatoCreationMintToday - mintArigatoCreationToday;
        uint256 remainingArigatoCreationMintTodayForGuest;

        AccountInfo memory accountInfo = _accountInfos[sender];

        bool isGuest = accountInfo.firstTransactionTime == accountInfo.lastModifiedMidnightBalanceTime;
        if (isGuest) {
            uint256 maxArigatoCreationMintTodayForGuest = maxArigatoCreationMintToday / 10;
            if (
                maxArigatoCreationMintTodayForGuest <= 0
                    || maxArigatoCreationMintTodayForGuest <= mintArigatoCreationTodayForGuest
            ) {
                console2.log("return 182");
                return;
            }
            remainingArigatoCreationMintTodayForGuest =
                maxArigatoCreationMintTodayForGuest - mintArigatoCreationTodayForGuest;
        }

        // ** Calculation of mint amount
        // increaseRate = (maxIncreaseRate - changeRate * abs(maxUsageRate - usageRate)) * valueOfMessageCharacter
        uint256 usageBp = rawAmount * BP_BASE / rawBalance;
        uint256 absUsageBp = usageBp > maxUsageBp ? usageBp - maxUsageBp : uint256(maxUsageBp) - usageBp;
        uint256 changeMulBp = uint256(changeBp) * absUsageBp / BP_BASE;
        if (changeMulBp >= maxIncreaseBp) {
            console2.log("changeMulBp >= maxIncreaseBp %s >= %s", changeMulBp, maxIncreaseBp);
            return;
        }
        uint256 messageLength = messageCharacters > 0 ? messageCharacters : 1;
        uint256 messageBp =
            messageLength > MAX_CHARACTER_LENGTH ? BP_BASE : messageLength * BP_BASE / MAX_CHARACTER_LENGTH;
        console2.log("rawAmount: %s, rawBalance: %s", rawAmount, rawBalance);
        console2.log("usageBp: %s, absUsageBp: %s", usageBp, absUsageBp);
        console2.log("messageLength: %s, messageBp: %s", messageLength, messageBp);
        console2.log("maxIncreaseBp: %s, changeBp: %s", maxIncreaseBp, uint256(changeBp));
        console2.log("changebpmul %s", changeMulBp);

        uint256 increaseBp = uint256(maxIncreaseBp) - changeMulBp * messageBp / BP_BASE;
        console2.log("increaseBp: %s", increaseBp);

        uint256 mintAmount = rawAmount * increaseBp / BP_BASE;
        console2.log("mintAmount: %s", mintAmount);
        if (mintAmount > remainingArigatoCreationMintToday) {
            console2.log("mintAmount > remainingArigatoCreationMintToday %s", remainingArigatoCreationMintToday);
            mintAmount = remainingArigatoCreationMintToday;
        }

        // ** Sender mint limit
        if (!isGuest) {
            console2.log("accountInfo.midnightBalance: %s", accountInfo.midnightBalance);
            console2.log("midnightTotalSupply: %s", midnightTotalSupply);
            uint256 maxArigatoCreationMintTodayForSender =
                maxArigatoCreationMintToday * accountInfo.midnightBalance / midnightTotalSupply;
            if (maxArigatoCreationMintTodayForSender <= 0) {
                console2.log(
                    "return maxArigatoCreationMintTodayForSender <= 0 %s", maxArigatoCreationMintTodayForSender
                );
                return;
            }
            if (mintAmount > maxArigatoCreationMintTodayForSender) {
                mintAmount = maxArigatoCreationMintTodayForSender;
            }
        } else {
            // Guest can mint only 1% of maxArigatoCreationMintToday
            if (mintAmount > remainingArigatoCreationMintTodayForGuest) {
                console2.log(
                    "mintAmount > remainingArigatoCreationMintTodayForGuest %s",
                    remainingArigatoCreationMintTodayForGuest
                );
                mintAmount = remainingArigatoCreationMintTodayForGuest;
            }
            uint256 maxArigatoCreationMintTodayForGuestSender = maxArigatoCreationMintToday / 100;
            if (maxArigatoCreationMintTodayForGuestSender <= 0) {
                console2.log(
                    "return maxArigatoCreationMintTodayForGuestSender <= 0 %s",
                    maxArigatoCreationMintTodayForGuestSender
                );
                return;
            }
            if (mintAmount > maxArigatoCreationMintTodayForGuestSender) {
                console2.log(
                    "mintAmount > maxArigatoCreationMintTodayForGuestSender %s",
                    maxArigatoCreationMintTodayForGuestSender
                );
                mintAmount = maxArigatoCreationMintTodayForGuestSender;
            }
        }

        // ** Execute mint
        _mint(sender, mintAmount);
        unchecked {
            accountInfo.mintArigatoCreationToday += mintAmount;
            mintArigatoCreationToday += mintAmount;
            if (isGuest) {
                mintArigatoCreationTodayForGuest += mintAmount;
            }
        }
        emit MintArigatoCreation(sender, rawBalanceToDisplayBalance(mintAmount), mintAmount);
        console2.log("complete mintAmount: %s", mintAmount);
    }

    function transfer(address receiver, uint256 displayAmount) public override returns (bool) {
        updateFactorIfNeeded();
        uint256 rawBalance = super.balanceOf(_msgSender());
        uint256 rawAmount = displayBalanceToRawBalance(displayAmount);
        // console2.log("rawBalance", rawBalance);
        // console2.log("rawAmount: %s, displayAmount: %s", rawAmount, displayAmount);
        bool ret = super.transfer(receiver, rawAmount);

        _mintArigatoCreation(_msgSender(), rawAmount, rawBalance, 1);

        return ret;
    }

    function _spendAllowance(address owner, address spender, uint256 value) internal virtual override {
        // PCECommunityToken's change
        // get raw allowance
        // - uint256 currentAllowance = allowance(owner, spender);
        // + uint256 currentAllowance = super.allowance(owner, spender);
        uint256 currentAllowance = super.allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < value) {
                revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            }
            unchecked {
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
    }

    function transferFrom(address sender, address receiver, uint256 displayBalance) public override returns (bool) {
        updateFactorIfNeeded();
        uint256 rawBalance = super.balanceOf(sender);
        uint256 rawAmount = displayBalanceToRawBalance(displayBalance);
        bool ret = super.transferFrom(sender, receiver, rawAmount);

        _mintArigatoCreation(sender, rawAmount, rawBalance, 1);

        return ret;
    }

    function approve(address spender, uint256 displayBalance) public override returns (bool) {
        updateFactorIfNeeded();
        uint256 rawBalance = displayBalanceToRawBalance(displayBalance);
        return super.approve(spender, rawBalance);
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return rawBalanceToDisplayBalance(super.allowance(owner, spender));
    }

    function mint(address to, uint256 displayBalance) external {
        updateFactorIfNeeded();
        _mint(to, displayBalanceToRawBalance(displayBalance));
    }

    function burn(uint256 displayBalance) public override {
        updateFactorIfNeeded();
        super.burn(displayBalanceToRawBalance(displayBalance));
    }

    function burnFrom(address account, uint256 displayBalance) public override {
        updateFactorIfNeeded();
        super.burnFrom(account, displayBalanceToRawBalance(displayBalance));
    }

    function intervalDaysOf(uint256 start, uint256 end, uint256 intervalDays) public pure returns (bool) {
        if (start >= end) {
            return false;
        }
        uint256 startDay = start / 1 days;
        uint256 endDay = end / 1 days;
        if (startDay == endDay) {
            return false;
        }
        return (endDay - startDay) >= intervalDays;
    }

    function _isAllowExchange(bool isIncome, address tokenAddress) private view returns (bool) {
        ExchangeAllowMethod allowMethod = isIncome ? incomeExchangeAllowMethod : outgoExchangeAllowMethod;
        address[] memory targetTokens = isIncome ? incomeTargetTokens : outgoTargetTokens;
        if (allowMethod == ExchangeAllowMethod.None) {
            return false;
        } else if (allowMethod == ExchangeAllowMethod.All) {
            return true;
        } else if (allowMethod == ExchangeAllowMethod.Include) {
            for (uint256 i = 0; i < targetTokens.length;) {
                if (targetTokens[i] == tokenAddress) {
                    return true;
                }
                unchecked {
                    i++;
                }
            }
            return false;
        } else if (allowMethod == ExchangeAllowMethod.Exclude) {
            for (uint256 i = 0; i < targetTokens.length;) {
                if (targetTokens[i] == tokenAddress) {
                    return false;
                }
                unchecked {
                    i++;
                }
            }
            return true;
        } else {
            revert("Invalid exchangeAllowMethod");
        }
    }

    function isAllowOutgoExchange(address tokenAddress) public view returns (bool) {
        return _isAllowExchange(false, tokenAddress);
    }

    function isAllowIncomeExchange(address tokenAddress) public view returns (bool) {
        return _isAllowExchange(true, tokenAddress);
    }

    /*
        @dev Swap tokens
        @param toTokenAddress Address of token to swap
        @param amountToSwap Amount of token to swap
    */

    function swapTokens(address toTokenAddress, uint256 amountToSwap) public {
        address sender = _msgSender();
        updateFactorIfNeeded();
        PCEToken pceToken = PCEToken(pceAddress);
        pceToken.updateFactorIfNeeded();

        Utils.LocalToken memory fromToken = pceToken.getLocalToken(address(this));
        require(fromToken.isExists, "From token not found");

        Utils.LocalToken memory toToken = pceToken.getLocalToken(toTokenAddress);
        require(toToken.isExists, "Target token not found");

        PCECommunityTokenV2 to = PCECommunityTokenV2(toTokenAddress);
        to.updateFactorIfNeeded();

        require(balanceOf(sender) >= amountToSwap, "Insufficient balance");
        require(isAllowOutgoExchange(toTokenAddress), "Outgo exchange not allowed");
        require(to.isAllowIncomeExchange(address(this)), "Income exchange not allowed");

        uint256 targetTokenAmount =
            amountToSwap * 10 ** 18 / fromToken.exchangeRate * pceToken.getCurrentFactor() / getCurrentFactor();
        targetTokenAmount = targetTokenAmount * toToken.exchangeRate / INITIAL_FACTOR * to.getCurrentFactor()
            / pceToken.getCurrentFactor();
        require(targetTokenAmount > 0, "Invalid amount to swap");

        super._burn(sender, displayBalanceToRawBalance(amountToSwap));
        to.mint(sender, targetTokenAmount);
    }

    /*
        @notice Returns the fee in this token for the meta transaction in the current block.
    */
    function getMetaTransactionFee() public view returns (uint256) {
        PCEToken pceToken = PCEToken(pceAddress);
        uint256 pceTokenFee = pceToken.getMetaTransactionFee();
        uint256 rate = pceToken.getSwapRate(address(this));
        return pceTokenFee * rate >> 96;
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 displayAmount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        public
        override
    {
        updateFactorIfNeeded();
        uint256 rawBalance = super.balanceOf(from);
        uint256 rawAmount = displayBalanceToRawBalance(displayAmount);
        uint256 displayFee = getMetaTransactionFee();
        uint256 rawFee = displayBalanceToRawBalance(displayFee);
        _transferWithAuthorization(from, to, displayAmount, validAfter, validBefore, nonce, v, r, s, rawAmount);

        super._transfer(from, _msgSender(), rawFee);

        emit MetaTransactionFeeCollected(from, _msgSender(), displayFee, rawFee);

        _mintArigatoCreation(from, rawAmount, rawBalance, 1);
    }

    function approveWithAuthorization(
        address owner,
        address spender,
        uint256 displayBalance,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        updateFactorIfNeeded();
        uint256 rawAmount = displayBalanceToRawBalance(displayBalance);
        uint256 displayFee = getMetaTransactionFee();
        uint256 rawFee = displayBalanceToRawBalance(displayFee);

        _approveWithAuthorization(owner, spender, displayBalance, validAfter, validBefore, nonce, v, r, s, rawAmount);
        super._transfer(owner, _msgSender(), rawFee);

        emit MetaTransactionFeeCollected(owner, _msgSender(), displayFee, rawFee);
    }

    /*
        @notice Returns the total balance that can be swapped to PCE today
        The balance is 0.01 times the total supply at UTC 0
    */
    function getTodaySwapableToPCEBalance() public view returns (uint256) {
        PCEToken pceToken = PCEToken(pceAddress);

        return rawBalanceToDisplayBalance(midnightTotalSupply * pceToken.swapableToPCERate() / BP_BASE);
    }

    /*
        @notice Returns the total balance that can be swapped to PCE today for the individual
        The balance is 0.01 times the balance of the individual at UTC 0
    */
    function getTodaySwapableToPCEBalanceForIndividual(address checkAddress) public view returns (uint256) {
        PCEToken pceToken = PCEToken(pceAddress);

        AccountInfo memory accountInfo = _accountInfos[checkAddress];

        return
            rawBalanceToDisplayBalance(accountInfo.midnightBalance * pceToken.swapableToPCEIndividualRate() / BP_BASE);
    }

    function version() public pure returns (string memory) {
        return "2.0.0";
    }
}
