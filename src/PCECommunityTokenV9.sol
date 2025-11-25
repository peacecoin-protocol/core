// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ERC20BurnableUpgradeable } from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { ERC20PermitUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { PCETokenV9 } from "./PCETokenV9.sol";
import { Utils } from "./lib/Utils.sol";
import { EIP3009 } from "./lib/EIP3009.sol";
import { EIP712 } from "./lib/EIP712.sol";
import { TokenSetting } from "./lib/TokenSetting.sol";
import { ExchangeAllowMethod } from "./lib/Enum.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { VoucherSystem } from "./lib/VoucherSystem.sol";

import { console2 } from "forge-std/console2.sol";

/// @custom:oz-upgrades-from PCECommunityTokenV8

contract PCECommunityTokenV9 is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    OwnableUpgradeable,
    EIP3009,
    ERC20PermitUpgradeable,
    TokenSetting
{
    uint256 public constant INITIAL_FACTOR = 10 ** 18;
    uint16 public constant BP_BASE = 10_000;
    uint16 public constant MAX_CHARACTER_LENGTH = 10;

    /*
        keccak256(
            "TransferFromWithAuthorization(address spender,address from,address to,
                uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
        )
    */
    bytes32 public constant TRANSFER_FROM_WITH_AUTHORIZATION_TYPEHASH =
        0xdc2e81fe1efc0fd8f409b4ea3e0551766bc1a7f569028058d8b21a404fd81480;

    /*
        keccak256(
            "SetInfinityApproveFlagWithAuthorization(address owner,address spender,
                bool flag,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
        )
    */
    bytes32 public constant SET_INFINITY_APPROVE_FLAG_WITH_AUTHORIZATION_TYPEHASH =
        0xae8989bee557ad51c17ff078fc59b7a54343dae31bac9bad6f6c9fe90486684e;

    /*
        keccak256(
            "ClaimWithAuthorization(address claimer,string issuanceId,string code,
                uint256 validAfter,uint256 validBefore,bytes32 nonce)"
        )
    */
    bytes32 public constant CLAIM_WITH_AUTHORIZATION_TYPEHASH =
        0x0b6aae1d90e3a85a25061f4c51e754a9cce2a86cf2f51fb09be1001de8fb7c0a;

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

    struct VoucherIssuanceInfo {
        string issuanceId;
        address owner;
        string name;
        uint256 amountPerClaim;
        uint256 countLimitPerUser;
        uint256 totalAmountLimit;
        uint256 startTime;
        uint256 endTime;
        bytes32 merkleRoot;
        bool isActive;
        uint256 remainingAmount;
        uint256 claimedAmount;
        uint256 claimedDisplayAmount;
        uint256 totalClaimCount;
        string ipfsCid;  // Optional IPFS CID for additional metadata
    }

    mapping(address user => AccountInfo accountInfo) private _accountInfos;
    mapping(address owner => mapping(address spender => bool flag)) private _infinityApproveFlags;

    VoucherSystem.VoucherStorage private _voucherStorage;

    event PCETransfer(address indexed from, address indexed to, uint256 displayAmount, uint256 rawAmount);
    event MintArigatoCreation(address indexed to, uint256 displayAmount, uint256 rawAmount);
    event MetaTransactionFeeCollected(address indexed from, address indexed to, uint256 displayFee, uint256 rawFee);
    event InfinityApproveFlagSet(address indexed owner, address indexed spender, bool flag);

    function initialize(string memory name, string memory symbol, uint256 _initialFactor) public initializer {
        __ERC20_init(name, symbol);
        __Ownable_init(_msgSender());
        __ERC20Permit_init(name);
        pceAddress = _msgSender();
        epochTime = block.timestamp;
        lastDecreaseTime = block.timestamp;
        initialFactor = _initialFactor;
        lastModifiedFactor = _initialFactor;
    }

    function getCurrentFactor() public view returns (uint256) {
        if (lastModifiedFactor == 0) {
            return 0;
        }
        if (decreaseIntervalDays == 0) {
            return lastModifiedFactor;
        }
        if (intervalDaysOf(lastDecreaseTime, block.timestamp, decreaseIntervalDays)) {
            return Math.mulDiv(lastModifiedFactor, afterDecreaseBp, BP_BASE);
        } else {
            return lastModifiedFactor;
        }
    }

    function updateFactorIfNeeded() public {
        if (lastDecreaseTime == block.timestamp) {
            return;
        }

        PCETokenV9 pceToken = PCETokenV9(pceAddress);
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
        uint256 maxArigatoCreationMintToday = Math.mulDiv(midnightTotalSupply, maxIncreaseOfTotalSupplyBp, BP_BASE);
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
            uint256 maxArigatoCreationMintTodayForGuest = Math.mulDiv(maxArigatoCreationMintToday, 1, 10);
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
        uint256 usageBp = Math.mulDiv(rawAmount, BP_BASE, rawBalance);
        uint256 absUsageBp = usageBp > maxUsageBp ? usageBp - maxUsageBp : uint256(maxUsageBp) - usageBp;
        uint256 changeMulBp = Math.mulDiv(uint256(changeBp), absUsageBp, BP_BASE);
        if (changeMulBp >= maxIncreaseBp) {
            console2.log("changeMulBp >= maxIncreaseBp %s >= %s", changeMulBp, maxIncreaseBp);
            return;
        }
        uint256 messageLength = messageCharacters > 0 ? messageCharacters : 1;
        uint256 messageBp =
            messageLength > MAX_CHARACTER_LENGTH ? BP_BASE : Math.mulDiv(messageLength, BP_BASE, MAX_CHARACTER_LENGTH);
        console2.log("rawAmount: %s, rawBalance: %s", rawAmount, rawBalance);
        console2.log("usageBp: %s, absUsageBp: %s", usageBp, absUsageBp);
        console2.log("messageLength: %s, messageBp: %s", messageLength, messageBp);
        console2.log("maxIncreaseBp: %s, changeBp: %s", maxIncreaseBp, uint256(changeBp));
        console2.log("changebpmul %s", changeMulBp);

        uint256 increaseBp = uint256(maxIncreaseBp) - Math.mulDiv(changeMulBp, messageBp, BP_BASE);
        console2.log("increaseBp: %s", increaseBp);

        uint256 mintAmount = Math.mulDiv(rawAmount, increaseBp, BP_BASE);
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
                Math.mulDiv(maxArigatoCreationMintToday, accountInfo.midnightBalance, midnightTotalSupply);
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
            uint256 maxArigatoCreationMintTodayForGuestSender = Math.mulDiv(maxArigatoCreationMintToday, 1, 100);
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
        // Check infinity approve flag first
        if (_infinityApproveFlags[owner][spender]) {
            return; // Skip allowance check if infinity approve flag is set
        }

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
        PCETokenV9 pceToken = PCETokenV9(pceAddress);
        pceToken.updateFactorIfNeeded();

        Utils.LocalToken memory fromToken = pceToken.getLocalToken(address(this));
        require(fromToken.isExists, "From token not found");

        Utils.LocalToken memory toToken = pceToken.getLocalToken(toTokenAddress);
        require(toToken.isExists, "Target token not found");

        PCECommunityTokenV9 to = PCECommunityTokenV9(toTokenAddress);
        to.updateFactorIfNeeded();

        require(balanceOf(sender) >= amountToSwap, "Insufficient balance");
        require(isAllowOutgoExchange(toTokenAddress), "Outgo exchange not allowed");
        require(to.isAllowIncomeExchange(address(this)), "Income exchange not allowed");

        uint256 targetTokenAmount = Math.mulDiv(
            Math.mulDiv(
                Math.mulDiv(amountToSwap, 10 ** 18, fromToken.exchangeRate),
                pceToken.getCurrentFactor(),
                getCurrentFactor()
            ),
            Math.mulDiv(toToken.exchangeRate, to.getCurrentFactor(), INITIAL_FACTOR),
            pceToken.getCurrentFactor()
        );

        require(targetTokenAmount > 0, "Invalid amount to swap");

        super._burn(sender, displayBalanceToRawBalance(amountToSwap));
        to.mint(sender, targetTokenAmount);
    }

    /*
        @notice Returns the fee in this token for the meta transaction in the current block.
    */
    function getMetaTransactionFee() public view returns (uint256) {
        PCETokenV9 pceToken = PCETokenV9(pceAddress);
        uint256 pceTokenFee = pceToken.getMetaTransactionFee();
        uint256 rate = pceToken.getSwapRate(address(this));
        return Math.mulDiv(pceTokenFee, rate, 2**96);
    }

    /*
        @notice Returns the fee in this token for the meta transaction with custom baseFee.
    */
    function getMetaTransactionFeeWithBaseFee(uint256 _baseFee) public view returns (uint256) {
        PCETokenV9 pceToken = PCETokenV9(pceAddress);
        uint256 pceTokenFee = pceToken.getMetaTransactionFeeWithBaseFee(_baseFee);
        uint256 rate = pceToken.getSwapRate(address(this));
        return Math.mulDiv(pceTokenFee, rate, 2**96);
    }

    function transferWithAuthorization(
        address from, address to, uint256 displayAmount, uint256 validAfter, uint256 validBefore, bytes32 nonce, uint8 v, bytes32 r, bytes32 s
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

    function transferFromWithAuthorization(
        address spender, address from, address to, uint256 displayAmount, uint256 validAfter, uint256 validBefore, bytes32 nonce, uint8 v, bytes32 r, bytes32 s
    )
        public
    {
        updateFactorIfNeeded();
        uint256 rawBalance = super.balanceOf(from);
        uint256 rawAmount = displayBalanceToRawBalance(displayAmount);
        uint256 displayFee = getMetaTransactionFee();
        uint256 rawFee = displayBalanceToRawBalance(displayFee);

        require(block.timestamp > validAfter, "Not yet valid");
        require(block.timestamp < validBefore, "Authorization expired");
        require(!_authorizationStates[spender][nonce], "Authorization used");
        require(rawBalance >= (rawAmount + rawFee), "Insufficient balance");
        require(_infinityApproveFlags[from][spender] || super.allowance(from, spender) >= rawAmount, "Insufficient allowance");

        bytes memory data = abi.encode(
            TRANSFER_FROM_WITH_AUTHORIZATION_TYPEHASH,
            spender,
            from,
            to,
            displayAmount,
            validAfter,
            validBefore,
            nonce
        );
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            this.DOMAIN_SEPARATOR(),
            keccak256(data)
        ));

        require(
            ecrecover(digest, v, r, s) == spender,
            "Invalid signature"
        );

        _authorizationStates[spender][nonce] = true;
        emit AuthorizationUsed(spender, nonce);

        _spendAllowance(from, spender, rawAmount);
        super._transfer(from, to, rawAmount);
        super._transfer(from, _msgSender(), rawFee);

        emit MetaTransactionFeeCollected(from, _msgSender(), displayFee, rawFee);
        _mintArigatoCreation(from, rawAmount, rawBalance, 1);
    }

    /*
        @notice Returns the total balance that can be swapped to PCE today
        The balance is 0.01 times the total supply at UTC 0
    */
    function getTodaySwapableToPCEBalance() public view returns (uint256) {
        PCETokenV9 pceToken = PCETokenV9(pceAddress);

        return rawBalanceToDisplayBalance(Math.mulDiv(midnightTotalSupply, pceToken.swapableToPCERate(), BP_BASE));
    }

    /*
        @notice Returns the total balance that can be swapped to PCE today for the individual
        The balance is 0.01 times the balance of the individual at UTC 0
    */
    function getTodaySwapableToPCEBalanceForIndividual(address checkAddress) public view returns (uint256) {
        PCETokenV9 pceToken = PCETokenV9(pceAddress);

        AccountInfo memory accountInfo = _accountInfos[checkAddress];
        uint256 individualRate = pceToken.swapableToPCEIndividualRate();
        uint256 rawAmount = Math.mulDiv(accountInfo.midnightBalance, individualRate, BP_BASE);

        return rawBalanceToDisplayBalance(rawAmount);
    }

    function setInfinityApproveFlag(address spender, bool flag) public {
        _infinityApproveFlags[_msgSender()][spender] = flag;
        emit InfinityApproveFlagSet(_msgSender(), spender, flag);
    }

    function getInfinityApproveFlag(address owner, address spender) public view returns (bool) {
        return _infinityApproveFlags[owner][spender];
    }

    function setInfinityApproveFlagWithAuthorization(
        address owner, address spender, bool flag, uint256 validAfter, uint256 validBefore, bytes32 nonce, uint8 v, bytes32 r, bytes32 s
    )
        public
    {
        updateFactorIfNeeded();
        uint256 displayFee = getMetaTransactionFee();
        uint256 rawFee = displayBalanceToRawBalance(displayFee);

        require(block.timestamp > validAfter, "Not yet valid");
        require(block.timestamp < validBefore, "Authorization expired");
        require(!_authorizationStates[owner][nonce], "Authorization used");
        require(super.balanceOf(owner) >= (rawFee), "Insufficient balance");

        bytes memory data = abi.encode(
            SET_INFINITY_APPROVE_FLAG_WITH_AUTHORIZATION_TYPEHASH,
            owner,
            spender,
            flag,
            validAfter,
            validBefore,
            nonce
        );
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            this.DOMAIN_SEPARATOR(),
            keccak256(data)
        ));

        require(
            ecrecover(digest, v, r, s) == owner,
            "Invalid signature"
        );

        _authorizationStates[owner][nonce] = true;
        emit AuthorizationUsed(owner, nonce);

        _infinityApproveFlags[owner][spender] = flag;
        emit InfinityApproveFlagSet(owner, spender, flag);

        // Collect meta transaction fee from owner
        super._transfer(owner, _msgSender(), rawFee);
        emit MetaTransactionFeeCollected(owner, _msgSender(), displayFee, rawFee);
    }

    // Voucher functions
    function registerVoucherIssuance(
        string memory issuanceId,
        string memory _name,
        uint256 _amountPerClaim,
        uint256 _countLimitPerUser,
        uint256 _totalAmountLimit,
        uint256 _initialFunds,
        uint256 _startTime,
        uint256 _endTime,
        bytes32 _merkleRoot,
        string memory _ipfsCid  // Optional IPFS CID (pass empty string if not needed)
    )
        external
    {
        uint256 initialFundsRawAmount = displayBalanceToRawBalance(_initialFunds);
        require(super.balanceOf(_msgSender()) >= initialFundsRawAmount, "Insufficient balance");

        VoucherSystem.registerIssuance(
            _voucherStorage,
            issuanceId,
            _name,
            _amountPerClaim,
            _countLimitPerUser,
            _totalAmountLimit,
            initialFundsRawAmount,
            _startTime,
            _endTime,
            _merkleRoot,
            _msgSender(),
            _ipfsCid
        );

        // Lock tokens from issuer
        super._transfer(_msgSender(), address(this), initialFundsRawAmount);
    }

    function claimVoucher(string memory issuanceId, string memory code, bytes32[] calldata proof) external {
        VoucherSystem.VoucherIssuance memory issuance = VoucherSystem.getIssuance(_voucherStorage, issuanceId);
        uint256 rawClaimAmount = displayBalanceToRawBalance(issuance.amountPerClaim);

        VoucherSystem.claim(_voucherStorage, issuanceId, code, proof, _msgSender(), rawClaimAmount);

        // Transfer tokens from contract to claimer
        super._transfer(address(this), _msgSender(), rawClaimAmount);
    }

    function claimVoucherWithAuthorization(
        address claimer,
        string memory issuanceId,
        string memory code,
        bytes32[] calldata proof,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
    {
        updateFactorIfNeeded();
        uint256 displayFee = getMetaTransactionFee();
        uint256 rawFee = displayBalanceToRawBalance(displayFee);

        require(block.timestamp > validAfter, "Not yet valid");
        require(block.timestamp < validBefore, "Authorization expired");
        require(!_authorizationStates[claimer][nonce], "Authorization used");

        bytes memory data = abi.encode(
            CLAIM_WITH_AUTHORIZATION_TYPEHASH,
            claimer,
            keccak256(bytes(issuanceId)),  // Note: string型は自動的にハッシュ化されるため、この実装が必要
            keccak256(bytes(code)),         // Note: string型は自動的にハッシュ化されるため、この実装が必要
            validAfter,
            validBefore,
            nonce
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", this.DOMAIN_SEPARATOR(), keccak256(data)));

        require(ecrecover(digest, v, r, s) == claimer, "Invalid signature");

        _authorizationStates[claimer][nonce] = true;
        emit AuthorizationUsed(claimer, nonce);

        // Get claim amount and convert to raw balance
        VoucherSystem.VoucherIssuance memory issuance = VoucherSystem.getIssuance(_voucherStorage, issuanceId);
        uint256 rawClaimAmount = displayBalanceToRawBalance(issuance.amountPerClaim);

        // Check if claim amount is greater than meta transaction fee
        require(rawClaimAmount > rawFee, "Claim amount must be greater than fee");

        // Claim from voucher
        VoucherSystem.claim(_voucherStorage, issuanceId, code, proof, claimer, rawClaimAmount);

        // Calculate amount after deducting fee
        uint256 amountAfterFee = rawClaimAmount - rawFee;

        // Transfer amount after fee to claimer
        super._transfer(address(this), claimer, amountAfterFee);

        // Collect meta transaction fee from claimed amount
        super._transfer(address(this), _msgSender(), rawFee);
        emit MetaTransactionFeeCollected(claimer, _msgSender(), displayFee, rawFee);
    }

    function getVoucherIssuanceInfo(string memory issuanceId)
        external
        view
        returns (VoucherIssuanceInfo memory)
    {
        VoucherSystem.VoucherIssuance memory issuance = VoucherSystem.getIssuance(_voucherStorage, issuanceId);
        (uint256 remainingRawAmount, uint256 claimedRawAmount, uint256 claimedDisplayAmount, uint256 totalClaimCount) =
            VoucherSystem.getFundsInfo(_voucherStorage, issuanceId);

        return VoucherIssuanceInfo({
            issuanceId: issuance.issuanceId,
            owner: issuance.owner,
            name: issuance.name,
            amountPerClaim: issuance.amountPerClaim,
            countLimitPerUser: issuance.countLimitPerUser,
            totalAmountLimit: issuance.totalAmountLimit,
            startTime: issuance.startTime,
            endTime: issuance.endTime,
            merkleRoot: issuance.merkleRoot,
            isActive: issuance.isActive,
            remainingAmount: rawBalanceToDisplayBalance(remainingRawAmount),
            claimedAmount: rawBalanceToDisplayBalance(claimedRawAmount),
            claimedDisplayAmount: claimedDisplayAmount,
            totalClaimCount: totalClaimCount,
            ipfsCid: issuance.ipfsCid
        });
    }

    function getVoucherIssuanceIds() external view returns (string[] memory) {
        return VoucherSystem.getIssuanceIds(_voucherStorage);
    }

    function canClaimVoucher(
        string memory issuanceId,
        string memory code,
        bytes32[] calldata proof,
        address claimer
    )
        external
        view
        returns (bool, uint8)
    {
        VoucherSystem.VoucherIssuance memory issuance = VoucherSystem.getIssuance(_voucherStorage, issuanceId);
        uint256 claimRawAmount = displayBalanceToRawBalance(issuance.amountPerClaim);
        return VoucherSystem.canClaim(_voucherStorage, issuanceId, code, proof, claimer, claimRawAmount);
    }

    function addVoucherFunds(string memory issuanceId, uint256 _amount) external {
        uint256 rawAmount = displayBalanceToRawBalance(_amount);
        require(super.balanceOf(_msgSender()) >= rawAmount, "Insufficient balance");

        VoucherSystem.addFunds(_voucherStorage, issuanceId, rawAmount, _msgSender());

        // Transfer tokens from sender to contract
        super._transfer(_msgSender(), address(this), rawAmount);
    }

    function withdrawVoucherFunds(string memory issuanceId, uint256 _amount) external {
        uint256 rawAmount = displayBalanceToRawBalance(_amount);

        uint256 withdrawnRawAmount = VoucherSystem.withdrawFunds(_voucherStorage, issuanceId, rawAmount, _msgSender());

        // Transfer tokens from contract to sender
        super._transfer(address(this), _msgSender(), withdrawnRawAmount);
    }

    function terminateVoucherIssuance(string memory issuanceId) external {
        uint256 remainingRawAmount = VoucherSystem.terminateIssuance(_voucherStorage, issuanceId, _msgSender());

        // Transfer remaining tokens from contract to sender
        if (remainingRawAmount > 0) {
            super._transfer(address(this), _msgSender(), remainingRawAmount);
        }
    }

    function setTokenSettings(
        uint256 _decreaseIntervalDays,
        uint16 _afterDecreaseBp,
        uint16 _maxIncreaseOfTotalSupplyBp,
        uint16 _maxIncreaseBp,
        uint16 _maxUsageBp,
        uint16 _changeBp,
        ExchangeAllowMethod _incomeExchangeAllowMethod,
        ExchangeAllowMethod _outgoExchangeAllowMethod,
        address[] calldata _incomeTargetTokens,
        address[] calldata _outgoTargetTokens
    )
        public
        override
        onlyOwner
    {
        super.setTokenSettings(
            _decreaseIntervalDays,
            _afterDecreaseBp,
            _maxIncreaseOfTotalSupplyBp,
            _maxIncreaseBp,
            _maxUsageBp,
            _changeBp,
            _incomeExchangeAllowMethod,
            _outgoExchangeAllowMethod,
            _incomeTargetTokens,
            _outgoTargetTokens
        );
    }

    function version() public pure returns (string memory) {
        return "1.0.9";
    }
}
