// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { ERC20PermitUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { PCEToken } from "./PCEToken.sol";
import { EIP3009 } from "./lib/EIP3009.sol";
import { ECRecover } from "./lib/ECRecover.sol";
import { TokenSetting } from "./lib/TokenSetting.sol";
import { ExchangeAllowMethod } from "./lib/Enum.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { VoucherSystem } from "./lib/VoucherSystem.sol";
import { TokenValueOps } from "./lib/TokenValueOps.sol";
import { ArigatoCreation } from "./lib/ArigatoCreation.sol";

contract PCECommunityToken is
    Initializable,
    ERC20Upgradeable,
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

    /*
        keccak256(
            "TransferWithAuthorizationWithMessageCount(address from,address to,uint256 value,
                uint256 validAfter,uint256 validBefore,bytes32 nonce,uint256 messageCount)"
        )
    */
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_WITH_MESSAGE_COUNT_TYPEHASH =
        0xbd5d42154bfea4ab9874186856d7f4024f087ed1d032940fc2bb1072cf855cfe;

    /*
        keccak256(
            "TransferFromWithAuthorizationWithMessageCount(address spender,address from,address to,uint256 value,
                uint256 validAfter,uint256 validBefore,bytes32 nonce,uint256 messageCount)"
        )
    */
    bytes32 public constant TRANSFER_FROM_WITH_AUTHORIZATION_WITH_MESSAGE_COUNT_TYPEHASH =
        0x13fcc8397683033a52e999616037110db35913dff276c6b4e8766d1acf918b9c;

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
        string ipfsCid;
    }

    mapping(address user => AccountInfo accountInfo) private _accountInfos;
    mapping(address owner => mapping(address spender => bool flag)) private _infinityApproveFlags;

    VoucherSystem.VoucherStorage private _voucherStorage;

    // --- V11: Daily swap-to-PCE tracking ---
    uint256 public swappedToPCEToday;
    uint256 public swappedToPCETodayModifiedTime;
    mapping(address => uint256) public swappedToPCETodayByAddress;
    mapping(address => uint256) public swappedToPCETodayByAddressModifiedTime;

    // --- V14: Treasury wallet and token value operations (PIP-12) ---
    address public treasuryWallet;
    bytes32 public constant RATE_MANAGER_ROLE = keccak256("RATE_MANAGER_ROLE");
    mapping(bytes32 => mapping(address => bool)) private _roles;
    uint256 public rebaseFactor;

    event PCETransfer(address indexed from, address indexed to, uint256 displayAmount, uint256 rawAmount);
    event MintArigatoCreation(address indexed to, uint256 displayAmount, uint256 rawAmount);
    event MetaTransactionFeeCollected(address indexed from, address indexed to, uint256 displayFee, uint256 rawFee);
    event MetaTransactionFeeSwapped(address indexed from, address indexed relayer, uint256 communityTokenFee, uint256 pceFee);
    event InfinityApproveFlagSet(address indexed owner, address indexed spender, bool flag);
    event TreasuryWalletSet(address indexed wallet);
    event TokenValueIncreased(uint256 pceAmount, uint256 oldExchangeRate, uint256 newExchangeRate);
    event TokenSplit(uint256 mintAmount, uint256 oldExchangeRate, uint256 newExchangeRate, uint256 oldRebaseFactor, uint256 newRebaseFactor);
    event RateManagerRoleGranted(address indexed account);
    event RateManagerRoleRevoked(address indexed account);
    event TransferWithMessageCount(address indexed from, address indexed to, uint256 displayAmount, uint256 messageCount);

    function initialize(string memory name, string memory symbol, uint256 _initialFactor) public initializer {
        require(_initialFactor > 0, "Initial factor must be > 0");
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
        uint256 startDay = lastDecreaseTime / 1 days;
        uint256 endDay = block.timestamp / 1 days;
        if (endDay <= startDay) {
            return lastModifiedFactor;
        }
        uint256 elapsed = endDay - startDay;
        if (elapsed < decreaseIntervalDays) {
            return lastModifiedFactor;
        }
        // Apply multiple decay periods via O(log n) exponentiation
        uint256 times = elapsed / decreaseIntervalDays;
        uint256 factor = lastModifiedFactor;
        uint256 rate = afterDecreaseBp;
        uint256 base = BP_BASE;
        uint256 n = times;
        while (n > 0) {
            if (n % 2 == 1) {
                factor = Math.mulDiv(factor, rate, base);
            }
            rate = Math.mulDiv(rate, rate, base);
            n /= 2;
        }
        return factor;
    }

    function updateFactorIfNeeded() public {
        if (lastDecreaseTime == block.timestamp) {
            return;
        }

        PCEToken pceToken = PCEToken(pceAddress);
        pceToken.updateFactorIfNeeded();

        if (decreaseIntervalDays == 0) return;

        uint256 startDay = lastDecreaseTime / 1 days;
        uint256 endDay = block.timestamp / 1 days;
        if (endDay <= startDay) return;
        uint256 elapsed = endDay - startDay;
        if (elapsed < decreaseIntervalDays) return;

        uint256 times = elapsed / decreaseIntervalDays;
        uint256 currentFactor = getCurrentFactor();
        if (currentFactor != lastModifiedFactor) {
            lastModifiedFactor = currentFactor;
            // Advance to the last decay boundary, not block.timestamp
            lastDecreaseTime = (startDay + (times * decreaseIntervalDays)) * 1 days;
        }
    }

    function rawBalanceToDisplayBalance(uint256 rawBalance) public view returns (uint256) {
        uint256 currentFactor = getCurrentFactor();
        if (currentFactor < 1) {
            currentFactor = 1;
        }
        uint256 base = Math.mulDiv(rawBalance, currentFactor, initialFactor * initialFactor);
        if (rebaseFactor == 0 || rebaseFactor == INITIAL_FACTOR) {
            return base;
        }
        return Math.mulDiv(base, rebaseFactor, INITIAL_FACTOR);
    }

    function displayBalanceToRawBalance(uint256 displayBalance) public view returns (uint256) {
        uint256 currentFactor = getCurrentFactor();
        if (currentFactor < 1) {
            currentFactor = 1;
        }
        uint256 display = displayBalance;
        if (rebaseFactor != 0 && rebaseFactor != INITIAL_FACTOR) {
            display = Math.mulDiv(displayBalance, INITIAL_FACTOR, rebaseFactor);
        }
        return Math.mulDiv(display, initialFactor * initialFactor, currentFactor);
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

    function _beforeTokenTransfer(address from, address to, uint256) internal {
        if (midnightTotalSupplyModifiedTime == 0) {
            // Use total supply instead of transfer amount to prevent manipulation
            midnightTotalSupply = super.totalSupply();
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
        AccountInfo storage accountInfo = _accountInfos[sender];

        (uint256 mintAmount, bool isGuest) = ArigatoCreation.compute(
            ArigatoCreation.AccountInfo({
                midnightBalance: accountInfo.midnightBalance,
                firstTransactionTime: accountInfo.firstTransactionTime,
                lastModifiedMidnightBalanceTime: accountInfo.lastModifiedMidnightBalanceTime,
                mintArigatoCreationToday: accountInfo.mintArigatoCreationToday
            }),
            ArigatoCreation.Params({
                midnightTotalSupply: midnightTotalSupply,
                maxIncreaseOfTotalSupplyBp: maxIncreaseOfTotalSupplyBp,
                maxIncreaseBp: maxIncreaseBp,
                maxUsageBp: maxUsageBp,
                changeBp: changeBp,
                mintArigatoCreationToday: mintArigatoCreationToday,
                mintArigatoCreationTodayForGuest: mintArigatoCreationTodayForGuest,
                rawAmount: rawAmount,
                rawBalance: rawBalance,
                messageCharacters: messageCharacters
            })
        );

        if (mintAmount == 0) return;

        _mint(sender, mintAmount);
        unchecked {
            accountInfo.mintArigatoCreationToday += mintAmount;
            mintArigatoCreationToday += mintAmount;
            if (isGuest) {
                mintArigatoCreationTodayForGuest += mintAmount;
            }
        }
        emit MintArigatoCreation(sender, rawBalanceToDisplayBalance(mintAmount), mintAmount);
    }

    function transfer(address receiver, uint256 displayAmount) public override returns (bool) {
        updateFactorIfNeeded();
        uint256 rawBalance = super.balanceOf(_msgSender());
        uint256 rawAmount = displayBalanceToRawBalance(displayAmount);
        bool ret = super.transfer(receiver, rawAmount);
        _mintArigatoCreation(_msgSender(), rawAmount, rawBalance, 1);
        return ret;
    }

    function transferWithMessageCount(address receiver, uint256 displayAmount, uint256 messageCount) public returns (bool) {
        updateFactorIfNeeded();
        uint256 rawBalance = super.balanceOf(_msgSender());
        uint256 rawAmount = displayBalanceToRawBalance(displayAmount);
        bool ret = super.transfer(receiver, rawAmount);
        _mintArigatoCreation(_msgSender(), rawAmount, rawBalance, messageCount);
        emit TransferWithMessageCount(_msgSender(), receiver, displayAmount, messageCount);
        return ret;
    }

    function _spendAllowance(address owner, address spender, uint256 value) internal virtual override {
        // Check infinity approve flag first
        if (_infinityApproveFlags[owner][spender]) {
            return; // Skip allowance check if infinity approve flag is set
        }

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

    function transferFromWithMessageCount(address sender, address receiver, uint256 displayBalance, uint256 messageCount) public returns (bool) {
        updateFactorIfNeeded();
        uint256 rawBalance = super.balanceOf(sender);
        uint256 rawAmount = displayBalanceToRawBalance(displayBalance);
        bool ret = super.transferFrom(sender, receiver, rawAmount);
        _mintArigatoCreation(sender, rawAmount, rawBalance, messageCount);
        emit TransferWithMessageCount(sender, receiver, displayBalance, messageCount);
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
        require(_msgSender() == pceAddress, "Only PCE token");
        updateFactorIfNeeded();
        _mint(to, displayBalanceToRawBalance(displayBalance));
    }

    function burn(uint256 displayBalance) public {
        updateFactorIfNeeded();
        _burn(_msgSender(), displayBalanceToRawBalance(displayBalance));
    }

    function burnFrom(address account, uint256 displayBalance) public {
        updateFactorIfNeeded();
        uint256 rawBalance = displayBalanceToRawBalance(displayBalance);
        _spendAllowance(account, _msgSender(), rawBalance);
        _burn(account, rawBalance);
    }

    function burnByPCEToken(address account, uint256 displayBalance) external {
        require(_msgSender() == pceAddress, "Only PCE token");
        updateFactorIfNeeded();
        _burn(account, displayBalanceToRawBalance(displayBalance));
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

    function isAllowOutgoExchange(address tokenAddress) public view returns (bool) {
        return TokenValueOps.isAllowExchange(
            false, tokenAddress, incomeExchangeAllowMethod, outgoExchangeAllowMethod, incomeTargetTokens, outgoTargetTokens
        );
    }

    function isAllowIncomeExchange(address tokenAddress) public view returns (bool) {
        return TokenValueOps.isAllowExchange(
            true, tokenAddress, incomeExchangeAllowMethod, outgoExchangeAllowMethod, incomeTargetTokens, outgoTargetTokens
        );
    }

    function swapTokens(address toTokenAddress, uint256 amountToSwap) public {
        address sender = _msgSender();
        updateFactorIfNeeded();
        PCEToken(pceAddress).updateFactorIfNeeded();
        PCECommunityToken to = PCECommunityToken(toTokenAddress);
        to.updateFactorIfNeeded();

        require(balanceOf(sender) >= amountToSwap, "Insufficient balance");
        require(isAllowOutgoExchange(toTokenAddress), "Outgo exchange not allowed");
        require(to.isAllowIncomeExchange(address(this)), "Income exchange not allowed");

        uint256 targetTokenAmount = TokenValueOps.computeSwapAmount(
            pceAddress, address(this), toTokenAddress, amountToSwap, getCurrentFactor(), to.getCurrentFactor()
        );
        super._burn(sender, displayBalanceToRawBalance(amountToSwap));
        to.mint(sender, targetTokenAmount);
    }

    function getMetaTransactionFee() public view returns (uint256) {
        return getMetaTransactionFeeWithBaseFee(block.basefee);
    }

    function getMetaTransactionFeeWithBaseFee(uint256 _baseFee) public view returns (uint256) {
        PCEToken pceToken = PCEToken(pceAddress);
        return Math.mulDiv(
            pceToken.getMetaTransactionFeeWithBaseFee(_baseFee),
            pceToken.getSwapRate(address(this)),
            2**96
        );
    }

    function _digest(bytes memory data) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", this.DOMAIN_SEPARATOR(), keccak256(data)));
    }

    function _useAuthorization(
        address authorizer,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes32 digest,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        internal
    {
        require(block.timestamp > validAfter, "Not yet valid");
        require(block.timestamp < validBefore, "Authorization expired");
        require(!_authorizationStates[authorizer][nonce], "Authorization used");
        require(ECRecover.recover(digest, v, r, s) == authorizer, "Invalid signature");
        _authorizationStates[authorizer][nonce] = true;
        emit AuthorizationUsed(authorizer, nonce);
    }

    function _collectFeeAsPCE(address from, address relayer, uint256 displayFee) internal returns (uint256) {
        // Preserve the pre-PIP-13 zero-fee behaviour: if the configured meta-tx
        // fee is zero there is nothing to collect and we must skip the swap so
        // the downstream `swapFeeFromLocalToken` non-zero check doesn't brick
        // meta-tx / voucher flows.
        if (displayFee == 0) return 0;

        uint256 rawFee = displayBalanceToRawBalance(displayFee);
        _burn(from, rawFee);
        PCEToken pceToken = PCEToken(pceAddress);
        uint256 pceAmount = pceToken.swapFeeFromLocalToken(address(this), relayer, displayFee);
        emit MetaTransactionFeeCollected(from, relayer, displayFee, rawFee);
        emit MetaTransactionFeeSwapped(from, relayer, displayFee, pceAmount);
        return pceAmount;
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

        require(rawAmount > 0, "Amount must be greater than zero");

        _transferWithAuthorization(from, to, displayAmount, validAfter, validBefore, nonce, v, r, s, rawAmount);

        _collectFeeAsPCE(from, _msgSender(), displayFee);

        _mintArigatoCreation(from, rawAmount, rawBalance, 1);
    }

    function transferFromWithAuthorization(
        address spender, address from, address to, uint256 displayAmount, uint256 validAfter, uint256 validBefore, bytes32 nonce, uint8 v, bytes32 r, bytes32 s
    )
        public
    {
        updateFactorIfNeeded();

        require(spender != address(0), "Invalid spender address");
        require(from != address(0), "Invalid from address");
        require(to != address(0), "Invalid to address");

        uint256 rawBalance = super.balanceOf(from);
        uint256 rawAmount = displayBalanceToRawBalance(displayAmount);
        uint256 displayFee = getMetaTransactionFee();
        uint256 rawFee = displayBalanceToRawBalance(displayFee);

        require(rawAmount > 0, "Amount must be greater than zero");
        require(rawBalance >= (rawAmount + rawFee), "Insufficient balance");
        require(
            _infinityApproveFlags[from][spender]
                || super.allowance(from, spender) >= (rawAmount + rawFee),
            "Insufficient allowance"
        );

        _useAuthorization(spender,
            validAfter,
            validBefore,
            nonce,
            _digest(abi.encode(
                TRANSFER_FROM_WITH_AUTHORIZATION_TYPEHASH,
                spender, from, to, displayAmount, validAfter, validBefore, nonce
            )),
            v, r, s
        );

        if (!_infinityApproveFlags[from][spender]) {
            _spendAllowance(from, spender, rawAmount + rawFee);
        }
        super._transfer(from, to, rawAmount);
        _collectFeeAsPCE(from, _msgSender(), displayFee);

        _mintArigatoCreation(from, rawAmount, rawBalance, 1);
    }

    function transferWithAuthorizationWithMessageCount(
        address from, address to, uint256 displayAmount, uint256 validAfter, uint256 validBefore, bytes32 nonce, uint8 v, bytes32 r, bytes32 s, uint256 messageCount
    )
        public
    {
        updateFactorIfNeeded();
        uint256 rawBalance = super.balanceOf(from);
        uint256 rawAmount = displayBalanceToRawBalance(displayAmount);
        uint256 displayFee = getMetaTransactionFee();

        require(rawAmount > 0, "Amount must be greater than zero");

        _useAuthorization(from,
            validAfter,
            validBefore,
            nonce,
            _digest(abi.encode(
                TRANSFER_WITH_AUTHORIZATION_WITH_MESSAGE_COUNT_TYPEHASH,
                from, to, displayAmount, validAfter, validBefore, nonce, messageCount
            )),
            v, r, s
        );

        super._transfer(from, to, rawAmount);
        _collectFeeAsPCE(from, _msgSender(), displayFee);

        emit TransferWithMessageCount(from, to, displayAmount, messageCount);

        _mintArigatoCreation(from, rawAmount, rawBalance, messageCount);
    }

    function transferFromWithAuthorizationWithMessageCount(
        address spender, address from, address to, uint256 displayAmount, uint256 validAfter, uint256 validBefore, bytes32 nonce, uint8 v, bytes32 r, bytes32 s, uint256 messageCount
    )
        public
    {
        updateFactorIfNeeded();

        require(spender != address(0), "Invalid spender address");
        require(from != address(0), "Invalid from address");
        require(to != address(0), "Invalid to address");

        uint256 rawBalance = super.balanceOf(from);
        uint256 rawAmount = displayBalanceToRawBalance(displayAmount);
        uint256 displayFee = getMetaTransactionFee();
        uint256 rawFee = displayBalanceToRawBalance(displayFee);

        require(rawAmount > 0, "Amount must be greater than zero");
        require(rawBalance >= (rawAmount + rawFee), "Insufficient balance");
        require(
            _infinityApproveFlags[from][spender]
                || super.allowance(from, spender) >= (rawAmount + rawFee),
            "Insufficient allowance"
        );

        _useAuthorization(spender,
            validAfter,
            validBefore,
            nonce,
            _digest(abi.encode(
                TRANSFER_FROM_WITH_AUTHORIZATION_WITH_MESSAGE_COUNT_TYPEHASH,
                spender, from, to, displayAmount, validAfter, validBefore, nonce, messageCount
            )),
            v, r, s
        );

        if (!_infinityApproveFlags[from][spender]) {
            _spendAllowance(from, spender, rawAmount + rawFee);
        }
        super._transfer(from, to, rawAmount);
        _collectFeeAsPCE(from, _msgSender(), displayFee);

        emit TransferWithMessageCount(from, to, displayAmount, messageCount);

        _mintArigatoCreation(from, rawAmount, rawBalance, messageCount);
    }

    /*
        @notice Returns the total balance that can be swapped to PCE today
        The balance is 0.01 times the total supply at UTC 0
    */
    function getTodaySwapableToPCEBalance() public view returns (uint256) {
        PCEToken pceToken = PCEToken(pceAddress);

        return rawBalanceToDisplayBalance(Math.mulDiv(midnightTotalSupply, pceToken.swapableToPCERate(), BP_BASE));
    }

    /*
        @notice Returns the total balance that can be swapped to PCE today for the individual
        The balance is 0.01 times the balance of the individual at UTC 0
    */
    function getTodaySwapableToPCEBalanceForIndividual(address checkAddress) public view returns (uint256) {
        PCEToken pceToken = PCEToken(pceAddress);

        AccountInfo memory accountInfo = _accountInfos[checkAddress];
        uint256 individualRate = pceToken.swapableToPCEIndividualRate();
        uint256 rawAmount = Math.mulDiv(accountInfo.midnightBalance, individualRate, BP_BASE);

        return rawBalanceToDisplayBalance(rawAmount);
    }

    // --- V11: Record daily swap-to-PCE usage ---
    function recordSwapToPCE(address account, uint256 displayAmount) external {
        require(_msgSender() == pceAddress, "Only PCE token");
        // Global daily reset
        if (intervalDaysOf(swappedToPCETodayModifiedTime, block.timestamp, 1)) {
            swappedToPCEToday = 0;
            swappedToPCETodayModifiedTime = block.timestamp;
        }
        if (swappedToPCETodayModifiedTime == 0) {
            swappedToPCETodayModifiedTime = block.timestamp;
        }
        // Individual daily reset
        if (intervalDaysOf(swappedToPCETodayByAddressModifiedTime[account], block.timestamp, 1)) {
            swappedToPCETodayByAddress[account] = 0;
            swappedToPCETodayByAddressModifiedTime[account] = block.timestamp;
        }
        if (swappedToPCETodayByAddressModifiedTime[account] == 0) {
            swappedToPCETodayByAddressModifiedTime[account] = block.timestamp;
        }
        swappedToPCEToday += displayAmount;
        swappedToPCETodayByAddress[account] += displayAmount;
    }

    // --- V11: Remaining swapable balance (global) ---
    function getRemainingSwapableToPCEBalance() public view returns (uint256) {
        uint256 limit = getTodaySwapableToPCEBalance();
        uint256 used = swappedToPCEToday;
        if (swappedToPCETodayModifiedTime == 0 || intervalDaysOf(swappedToPCETodayModifiedTime, block.timestamp, 1)) {
            used = 0;
        }
        return limit > used ? limit - used : 0;
    }

    // --- V11: Remaining swapable balance (individual) ---
    function getRemainingSwapableToPCEBalanceForIndividual(address account) public view returns (uint256) {
        uint256 limit = getTodaySwapableToPCEBalanceForIndividual(account);
        uint256 used = swappedToPCETodayByAddress[account];
        if (swappedToPCETodayByAddressModifiedTime[account] == 0 || intervalDaysOf(swappedToPCETodayByAddressModifiedTime[account], block.timestamp, 1)) {
            used = 0;
        }
        return limit > used ? limit - used : 0;
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

        require(owner != address(0), "Invalid owner address");
        require(spender != address(0), "Invalid spender address");

        uint256 displayFee = getMetaTransactionFee();
        uint256 rawFee = displayBalanceToRawBalance(displayFee);
        require(super.balanceOf(owner) >= rawFee, "Insufficient balance");

        _useAuthorization(owner,
            validAfter,
            validBefore,
            nonce,
            _digest(abi.encode(
                SET_INFINITY_APPROVE_FLAG_WITH_AUTHORIZATION_TYPEHASH,
                owner, spender, flag, validAfter, validBefore, nonce
            )),
            v, r, s
        );

        _infinityApproveFlags[owner][spender] = flag;
        emit InfinityApproveFlagSet(owner, spender, flag);

        _collectFeeAsPCE(owner, _msgSender(), displayFee);
    }

    // ====================================================================
    // Voucher functions (delegated to VoucherSystem library)
    //
    // Heavy logic lives in VoucherSystem.sol as public (linked) functions;
    // `__libTransfer` / `__libCollectFeeAsPCE` below are self-call hooks the
    // library uses to reach internal ERC20 transfers and fee collection.
    // ====================================================================

    modifier onlySelf() {
        require(msg.sender == address(this), "Only self");
        _;
    }

    function __libTransfer(address from, address to, uint256 rawAmount) external onlySelf {
        super._transfer(from, to, rawAmount);
    }

    function __libCollectFeeAsPCE(address from, address relayer, uint256 displayFee) external onlySelf {
        _collectFeeAsPCE(from, relayer, displayFee);
    }

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
        string memory _ipfsCid
    )
        external
    {
        VoucherSystem.registerIssuanceWithLock(
            _voucherStorage,
            issuanceId,
            _name,
            _amountPerClaim,
            _countLimitPerUser,
            _totalAmountLimit,
            _initialFunds,
            _startTime,
            _endTime,
            _merkleRoot,
            _ipfsCid
        );
    }

    function claimVoucher(string memory issuanceId, string memory code, bytes32[] calldata proof) external {
        VoucherSystem.claimAndTransfer(_voucherStorage, issuanceId, code, proof);
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
        require(claimer != address(0), "Invalid claimer address");
        VoucherSystem.claimWithAuthorizationAndTransfer(
            _voucherStorage,
            _authorizationStates,
            claimer,
            issuanceId,
            code,
            proof,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s,
            _msgSender()
        );
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
        VoucherSystem.addFundsWithTransfer(_voucherStorage, issuanceId, _amount);
    }

    function withdrawVoucherFunds(string memory issuanceId, uint256 _amount) external {
        VoucherSystem.withdrawFundsWithTransfer(_voucherStorage, issuanceId, _amount);
    }

    function terminateVoucherIssuance(string memory issuanceId) external {
        VoucherSystem.terminateWithRefund(_voucherStorage, issuanceId);
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

    // --- V14: Treasury wallet and token value operations (PIP-12) ---

    modifier onlyRateManager() {
        require(_roles[RATE_MANAGER_ROLE][_msgSender()], "Not rate manager");
        _;
    }

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }

    function initializeTreasury(address wallet) external onlyOwner {
        (treasuryWallet, rebaseFactor) =
            TokenValueOps.initializeTreasury(treasuryWallet, wallet, _msgSender(), _roles, RATE_MANAGER_ROLE);
    }

    function setTreasuryWallet(address wallet) external onlyRateManager {
        treasuryWallet = TokenValueOps.setTreasuryWallet(wallet);
    }

    function increaseTokenValue(uint256 pceAmount) external onlyRateManager {
        TokenValueOps.increaseTokenValue(pceAmount, pceAddress, address(this), treasuryWallet);
    }

    function splitToken(uint256 mintAmount) external onlyRateManager {
        rebaseFactor = TokenValueOps.splitToken(mintAmount, totalSupply(), rebaseFactor, pceAddress, address(this));
    }

    function grantRateManagerRole(address account) external onlyRateManager {
        TokenValueOps.grantRateManagerRole(account, _roles, RATE_MANAGER_ROLE);
    }

    function revokeRateManagerRole(address account) external onlyRateManager {
        TokenValueOps.revokeRateManagerRole(account, _roles, RATE_MANAGER_ROLE);
    }

    function version() public pure returns (string memory) {
        return "1.0.15";
    }
}
