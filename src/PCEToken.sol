// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ERC20BurnableUpgradeable } from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { PCECommunityToken } from "./PCECommunityToken.sol";
import { Utils } from "./lib/Utils.sol";
import { ExchangeAllowMethod } from "./lib/Enum.sol";
import { NativeMetaTransaction } from "./lib/polygon/NativeMetaTransaction.sol";
import { ContextMixin } from "./lib/polygon/ContextMixin.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { EIP712 } from "./lib/EIP712.sol";
import { AuthorizationSignature } from "./lib/AuthorizationSignature.sol";

contract PCEToken is
    UUPSUpgradeable,
    Initializable,
    ERC20Upgradeable,
    OwnableUpgradeable,
    ERC20BurnableUpgradeable,
    NativeMetaTransaction,
    ContextMixin,
    ReentrancyGuardTransient
{
    uint160 public nativeTokenToPceTokenRate;
    uint256 public metaTransactionGas;
    uint256 public metaTransactionPriorityFee;

    // Daily swap rate from community token to PCE in basis points
    uint256 public swapableToPCERate;
    // Individual daily swap limit from community token to PCE in basis points
    uint256 public swapableToPCEIndividualRate;

    address private _communityTokenAddress;
    address[] public tokens;
    mapping(address deployedAddress => Utils.LocalToken localToken) public localTokens;

    address public polygonChainManager;

    event TokenCreated(
        address indexed tokenAddress, address indexed creator, uint256 pcetokenAmount, uint256 newTokenAmount
    );
    event TokensSwappedToLocalToken(
        address indexed from, address indexed toToken, uint256 pceTokenAmount, uint256 targetTokenAmount
    );
    event TokensSwappedFromLocalToken(
        address indexed to, address indexed fromToken, uint256 targetTokenAmount, uint256 pceTokenAmount
    );
    event TokensSwappedBetweenLocalTokens(
        address indexed account,
        address indexed fromToken,
        address indexed toToken,
        uint256 fromTokenAmount,
        uint256 pceTokenAmount,
        uint256 targetTokenAmount
    );
    event FeeSwappedFromLocalToken(
        address indexed fromToken, address indexed relayer, uint256 communityTokenAmount, uint256 pceAmount
    );
    event TokenValueIncreased(
        address indexed communityToken, uint256 pceAmount, uint256 oldExchangeRate, uint256 newExchangeRate
    );
    event TokenSplit(
        address indexed communityToken,
        uint256 mintAmount,
        uint256 oldExchangeRate,
        uint256 newExchangeRate,
        uint256 oldRebaseFactor,
        uint256 newRebaseFactor
    );

    uint256 public constant INITIAL_FACTOR = 10 ** 18;
    uint256 private constant BP_BASE = 10_000;
    uint256 private constant Q96 = 2 ** 96;
    // 998/1000 = 0.998 (represents a 0.2% decrease)
    uint256 public constant DECREASE_RATE = 998 * (10 ** 18);
    uint256 public constant DECREASE_RATE_BASE = 1000 * (10 ** 18);

    uint256 public epochTime;
    uint256 public lastDecreaseTime;
    uint256 public lastModifiedFactor;

    // --- V17: EIP-3009 style authorization nonces for the `bytes` signature functions ---
    mapping(address authorizer => mapping(bytes32 nonce => bool isUsed)) private _authorizationStates;

    // --- V18: Daily cap on PCE leaving each community token's reserve ---
    /// @dev Packed into one slot. `day` is the UTC day number (`block.timestamp / 1 days`).
    struct DailyOutflow {
        uint112 midnightDeposited;
        uint112 outflowToday;
        uint32 day;
    }

    mapping(address communityToken => DailyOutflow dailyOutflow) private _dailyOutflows;

    /// @dev Signed under the domain {name: "PCE Token", version: "1", chainId, verifyingContract}.
    bytes32 public constant SWAP_TO_LOCAL_TOKEN_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "SwapToLocalTokenWithAuthorization(address from,address toToken,uint256 value,uint256 minAmountOut,uint256 maxFee,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    event AuthorizationExecuted(address indexed authorizer, bytes32 indexed nonce, bytes32 structHash);

    function initialize() public initializer {
        __ERC20_init("PCE Token", "PCE");
        __Ownable_init(_msgSender());
        __ERC20Burnable_init();
        _initializeEIP712("PCE Token");
        epochTime = block.timestamp;
        lastDecreaseTime = block.timestamp;
        lastModifiedFactor = INITIAL_FACTOR;
    }

    function getLocalToken(address communityToken) public view returns (Utils.LocalToken memory) {
        return localTokens[communityToken];
    }

    /// @notice Initialize the native meta-transaction domain on a legacy proxy.
    /// @dev Call atomically with the upgrade when the existing domain is zero.
    /// Uses the existing Polygon initialization flag without resetting nonces.
    function initializeNativeMetaTransaction() external onlyProxy onlyOwner {
        require(getDomainSeperator() == bytes32(0), "NativeMetaTransaction: DOMAIN_ALREADY_INITIALIZED");
        _initializeEIP712(name());
    }

    function _msgSender() internal view override returns (address) {
        return ContextMixin.msgSender();
    }

    function getCurrentFactor() public view returns (uint256) {
        if (lastModifiedFactor == 0) {
            return 0;
        }
        // Count actual Wednesdays crossed for multiple-week decay
        uint256 times = countWednesdaysBetween(lastDecreaseTime, block.timestamp);
        if (times == 0) {
            return lastModifiedFactor;
        }
        // O(log n) exponentiation
        uint256 factor = lastModifiedFactor;
        uint256 rate = DECREASE_RATE;
        uint256 base = DECREASE_RATE_BASE;
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

        uint256 times = countWednesdaysBetween(lastDecreaseTime, block.timestamp);
        if (times == 0) return;

        uint256 currentFactor = getCurrentFactor();
        if (currentFactor != lastModifiedFactor) {
            lastModifiedFactor = currentFactor;
            // Advance to the last Wednesday boundary, not block.timestamp
            uint256 endDay = block.timestamp / 1 days;
            uint256 endWeekday = endDay % 7;
            uint256 lastWedDay = endDay - ((endWeekday + 1) % 7);
            lastDecreaseTime = lastWedDay * 1 days;
        }
    }

    function transfer(address receiver, uint256 balance) public override returns (bool) {
        updateFactorIfNeeded();
        return super.transfer(receiver, balance);
    }

    function transferFrom(address sender, address receiver, uint256 balance) public override returns (bool) {
        updateFactorIfNeeded();
        return super.transferFrom(sender, receiver, balance);
    }

    function approve(address spender, uint256 balance) public override returns (bool) {
        updateFactorIfNeeded();
        return super.approve(spender, balance);
    }

    function mint(address to, uint256 balance) external onlyOwner {
        updateFactorIfNeeded();
        _mint(to, balance);
    }

    function getTokens() public view returns (address[] memory) {
        return tokens;
    }

    function setCommunityTokenAddress(address communityTokenAddress) external onlyOwner {
        _communityTokenAddress = communityTokenAddress;
    }

    function createToken(
        string memory name,
        string memory symbol,
        uint256 amountToExchange,
        uint256 dilutionFactor,
        uint256 decreaseIntervalDays,
        uint16 afterDecreaseBp,
        uint16 maxIncreaseOfTotalSupplyBp,
        uint16 maxIncreaseBp,
        uint16 maxUsageBp,
        uint16 changeBp,
        ExchangeAllowMethod incomeExchangeAllowMethod,
        ExchangeAllowMethod outgoExchangeAllowMethod,
        address[] calldata incomeTargetTokens,
        address[] calldata outgoTargetTokens
    )
        public
    {
        require(amountToExchange > 0, "Amount must be > 0");
        require(balanceOf(_msgSender()) >= amountToExchange, "Insufficient PCEToken bal.");
        require(dilutionFactor >= 10 ** 17 && dilutionFactor <= 10 ** 21, "Dilution factor 0.1-1000");
        require(afterDecreaseBp <= 10_000, "After decrease bp <= 10000");

        updateFactorIfNeeded();

        BeaconProxy proxy = new BeaconProxy(
            _communityTokenAddress,
            abi.encodeWithSelector(PCECommunityToken(address(0)).initialize.selector, name, symbol, lastModifiedFactor)
        );
        address newTokenAddress = address(proxy);
        PCECommunityToken newToken = PCECommunityToken(newTokenAddress);
        newToken.setTokenSettings(
            decreaseIntervalDays,
            afterDecreaseBp,
            maxIncreaseOfTotalSupplyBp,
            maxIncreaseBp,
            maxUsageBp,
            changeBp,
            incomeExchangeAllowMethod,
            outgoExchangeAllowMethod,
            incomeTargetTokens,
            outgoTargetTokens
        );

        uint256 newTokenAmount = (amountToExchange * dilutionFactor) / INITIAL_FACTOR;
        _transfer(_msgSender(), address(this), amountToExchange);
        newToken.mint(_msgSender(), newTokenAmount);

        _syncDailyOutflow(newTokenAddress);
        localTokens[newTokenAddress] = Utils.LocalToken(true, dilutionFactor, amountToExchange);
        tokens.push(newTokenAddress);

        newToken.transferOwnership(_msgSender());

        emit TokenCreated(newTokenAddress, _msgSender(), amountToExchange, newTokenAmount);
    }

    /// @notice Today's cap on PCE leaving `communityToken`'s reserve through swaps to PCE, and the
    /// PCE already counted against it. The cap is `swapableToPCERate` of the reserve at the start of
    /// the UTC day. Relayer fees and inter-community swaps are not counted.
    function getDailyPCEOutflow(address communityToken) public view returns (uint256 limit, uint256 used) {
        DailyOutflow memory outflow = _dailyOutflows[communityToken];
        uint256 midnightDeposited = outflow.midnightDeposited;
        if (outflow.day != block.timestamp / 1 days) {
            midnightDeposited = Math.min(localTokens[communityToken].depositedPCEToken, type(uint112).max);
        } else {
            used = outflow.outflowToday;
        }
        limit = Math.mulDiv(midnightDeposited, swapableToPCERate, BP_BASE);
    }

    /// @notice PCE that can still leave `communityToken`'s reserve today through swaps to PCE.
    function getRemainingDailyPCEOutflow(address communityToken) public view returns (uint256) {
        (uint256 limit, uint256 used) = getDailyPCEOutflow(communityToken);
        return limit > used ? limit - used : 0;
    }

    /// @notice `getDailyPCEOutflow`'s cap and remaining amount in `communityToken` display units.
    function getDailyPCEOutflowInToken(address communityToken)
        external
        view
        returns (uint256 limit, uint256 remaining)
    {
        (uint256 pceLimit, uint256 used) = getDailyPCEOutflow(communityToken);
        limit = _pceToTokenDisplay(communityToken, pceLimit);
        remaining = _pceToTokenDisplay(communityToken, pceLimit > used ? pceLimit - used : 0);
    }

    /// @dev The inverse of the `swapFromLocalToken` conversion, rounded down.
    function _pceToTokenDisplay(address communityToken, uint256 pceAmount) internal view returns (uint256) {
        return Math.mulDiv(
            Math.mulDiv(pceAmount, localTokens[communityToken].exchangeRate, INITIAL_FACTOR),
            PCECommunityToken(communityToken).getCurrentFactor(),
            getCurrentFactor()
        );
    }

    /// @dev Record the reserve as of the start of the UTC day. Called before every change to
    /// `depositedPCEToken`, so the first call of a day sees the reserve as it was at midnight.
    function _syncDailyOutflow(address communityToken) internal {
        uint32 today = SafeCast.toUint32(block.timestamp / 1 days);
        if (_dailyOutflows[communityToken].day != today) {
            uint256 deposited = Math.min(localTokens[communityToken].depositedPCEToken, type(uint112).max);
            _dailyOutflows[communityToken] = DailyOutflow(uint112(deposited), 0, today);
        }
    }

    function getDepositedPCETokens(address communityToken) public view returns (uint256) {
        require(localTokens[communityToken].isExists, "Target token not found");

        return localTokens[communityToken].depositedPCEToken;
    }

    function getExchangeRate(address communityToken) public view returns (uint256) {
        require(localTokens[communityToken].isExists, "Target token not found");

        return localTokens[communityToken].exchangeRate;
    }

    function getSwapRate(address toToken) public view returns (uint256) {
        require(localTokens[toToken].isExists, "Target token not found");

        PCECommunityToken target = PCECommunityToken(toToken);

        return Math.mulDiv(
            localTokens[toToken].exchangeRate * Q96, target.getCurrentFactor(), INITIAL_FACTOR * getCurrentFactor()
        );
    }

    function getSwapRateBetweenTokens(address fromToken, address toToken) public view returns (uint256) {
        require(localTokens[fromToken].isExists, "From token not found");
        require(localTokens[toToken].isExists, "Target token not found");

        PCECommunityToken fromTarget = PCECommunityToken(fromToken);
        PCECommunityToken toTarget = PCECommunityToken(toToken);

        uint256 exchangeRateRatio =
            Math.mulDiv(localTokens[toToken].exchangeRate, INITIAL_FACTOR, localTokens[fromToken].exchangeRate);

        uint256 currentFactorRatio =
            Math.mulDiv(toTarget.getCurrentFactor(), INITIAL_FACTOR, fromTarget.getCurrentFactor());

        uint256 result = Math.mulDiv(exchangeRateRatio, currentFactorRatio, INITIAL_FACTOR);
        return result;
    }

    function swapToLocalToken(address toToken, uint256 amountToSwap) public {
        _swapToLocalToken(_msgSender(), toToken, amountToSwap);
    }

    function _swapToLocalToken(address account, address toToken, uint256 amountToSwap) internal {
        updateFactorIfNeeded();
        require(localTokens[toToken].isExists, "Target token not found");
        require(balanceOf(account) >= amountToSwap, "Not enough PCEToken balance");

        PCECommunityToken target = PCECommunityToken(toToken);
        target.updateFactorIfNeeded();

        uint256 targetTokenAmount = Math.mulDiv(
            Math.mulDiv(amountToSwap, localTokens[toToken].exchangeRate, INITIAL_FACTOR),
            target.getCurrentFactor(),
            lastModifiedFactor
        );
        require(targetTokenAmount > 0, "Invalid amount to swap");

        _transfer(account, address(this), amountToSwap);
        target.mint(account, targetTokenAmount);

        _syncDailyOutflow(toToken);
        localTokens[toToken].depositedPCEToken = localTokens[toToken].depositedPCEToken + amountToSwap;

        emit TokensSwappedToLocalToken(account, toToken, amountToSwap, targetTokenAmount);
    }

    function swapFromLocalToken(address fromToken, uint256 amountToSwap) public {
        _swapFromLocalToken(fromToken, _msgSender(), amountToSwap);
    }

    /// @notice Swap `account`'s community tokens to PCE.
    /// @dev Only callable by the registered community token itself, for its meta-transaction swap.
    function swapFromLocalTokenFor(address account, uint256 amountToSwap) external {
        require(localTokens[msg.sender].isExists, "Caller must be a community token");
        _swapFromLocalToken(msg.sender, account, amountToSwap);
    }

    function _swapFromLocalToken(address fromToken, address account, uint256 amountToSwap) internal {
        updateFactorIfNeeded();
        require(localTokens[fromToken].isExists, "Target token not found");

        PCECommunityToken target = PCECommunityToken(fromToken);
        target.updateFactorIfNeeded();

        require(target.balanceOf(account) >= amountToSwap, "Insufficient balance");

        uint256 pcetokenAmount = Math.mulDiv(
            Math.mulDiv(amountToSwap, INITIAL_FACTOR, localTokens[fromToken].exchangeRate),
            lastModifiedFactor,
            target.getCurrentFactor()
        );
        require(pcetokenAmount > 0, "Target token deposit low");

        require(target.getRemainingSwapableToPCEBalance() >= amountToSwap, "Exceeds daily swap limit");
        require(
            target.getRemainingSwapableToPCEBalanceForIndividual(account) >= amountToSwap,
            "Exceeds daily individual swap limit"
        );

        // Explicit underflow guard with clear error message
        require(localTokens[fromToken].depositedPCEToken >= pcetokenAmount, "Insufficient deposited PCE token reserve");

        _syncDailyOutflow(fromToken);
        DailyOutflow storage outflow = _dailyOutflows[fromToken];
        uint256 outflowToday = outflow.outflowToday + pcetokenAmount;
        require(
            outflowToday <= Math.mulDiv(outflow.midnightDeposited, swapableToPCERate, BP_BASE),
            "Exceeds daily PCE outflow limit"
        );
        outflow.outflowToday = SafeCast.toUint112(outflowToday);

        target.burnByPCEToken(account, amountToSwap);
        target.recordSwapToPCE(account, amountToSwap);
        _transfer(address(this), account, pcetokenAmount);

        localTokens[fromToken].depositedPCEToken -= pcetokenAmount;

        emit TokensSwappedFromLocalToken(account, fromToken, amountToSwap, pcetokenAmount);
    }

    /// @notice Move value between two registered community tokens on behalf of `account`.
    /// @dev Only callable by the source community token after it has burned `amountToSwap`
    /// from `account` and applied its exchange checks. The accounting equals
    /// `swapFromLocalToken` followed by `swapToLocalToken`: the PCE reserve moves from the
    /// source token to the target token, and the target token is minted by this contract.
    function swapBetweenLocalTokens(
        address toToken,
        address account,
        uint256 amountToSwap
    )
        external
        returns (uint256 targetTokenAmount)
    {
        address fromToken = msg.sender;
        require(localTokens[fromToken].isExists, "Caller must be a community token");
        require(localTokens[toToken].isExists, "Target token not found");

        updateFactorIfNeeded();

        PCECommunityToken source = PCECommunityToken(fromToken);
        PCECommunityToken target = PCECommunityToken(toToken);
        target.updateFactorIfNeeded();

        uint256 pcetokenAmount = Math.mulDiv(
            Math.mulDiv(amountToSwap, INITIAL_FACTOR, localTokens[fromToken].exchangeRate),
            lastModifiedFactor,
            source.getCurrentFactor()
        );
        require(pcetokenAmount > 0, "Target token deposit low");
        require(localTokens[fromToken].depositedPCEToken >= pcetokenAmount, "Insufficient deposited PCE token reserve");

        targetTokenAmount = Math.mulDiv(
            Math.mulDiv(pcetokenAmount, localTokens[toToken].exchangeRate, INITIAL_FACTOR),
            target.getCurrentFactor(),
            lastModifiedFactor
        );
        require(targetTokenAmount > 0, "Invalid amount to swap");

        _syncDailyOutflow(fromToken);
        _syncDailyOutflow(toToken);
        localTokens[fromToken].depositedPCEToken -= pcetokenAmount;
        localTokens[toToken].depositedPCEToken += pcetokenAmount;

        target.mint(account, targetTokenAmount);

        emit TokensSwappedBetweenLocalTokens(
            account, fromToken, toToken, amountToSwap, pcetokenAmount, targetTokenAmount
        );
    }

    function swapFeeFromLocalToken(
        address fromToken,
        address relayer,
        uint256 communityTokenDisplayAmount
    )
        external
        returns (uint256)
    {
        require(msg.sender == fromToken, "Caller must be the community token");
        require(localTokens[fromToken].isExists, "Token not registered");

        // A zero-fee meta-tx is valid (the relayer simply waives the fee).
        // Short-circuit so the `pcetokenAmount > 0` check below doesn't brick
        // callers when `communityTokenDisplayAmount` is 0.
        if (communityTokenDisplayAmount == 0) return 0;

        updateFactorIfNeeded();

        PCECommunityToken target = PCECommunityToken(fromToken);

        // Intentional: relayer fee conversion is exempt from ordinary daily
        // community/personal swap limits, including paid voucher onboarding.
        uint256 pcetokenAmount = Math.mulDiv(
            Math.mulDiv(communityTokenDisplayAmount, INITIAL_FACTOR, localTokens[fromToken].exchangeRate),
            lastModifiedFactor,
            target.getCurrentFactor()
        );
        require(pcetokenAmount > 0, "Fee swap amount too small");
        require(localTokens[fromToken].depositedPCEToken >= pcetokenAmount, "Insufficient deposited PCE token reserve");

        _transfer(address(this), relayer, pcetokenAmount);
        _syncDailyOutflow(fromToken);
        localTokens[fromToken].depositedPCEToken -= pcetokenAmount;

        emit FeeSwappedFromLocalToken(fromToken, relayer, communityTokenDisplayAmount, pcetokenAmount);

        return pcetokenAmount;
    }

    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool) {
        return _authorizationStates[authorizer][nonce];
    }

    /// @notice Swap PCE to a community token on behalf of `from`.
    /// @dev The signature is 65-byte ECDSA (r || s || v) or ERC-1271. `minAmountOut` is compared with
    /// the increase of `from`'s display balance of `toToken`. The fee is `getMetaTransactionFee()` in
    /// PCE, capped by `maxFee`, and paid to the caller (the relayer).
    function swapToLocalTokenWithAuthorization(
        address from,
        address toToken,
        uint256 value,
        uint256 minAmountOut,
        uint256 maxFee,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    )
        external
        nonReentrant
    {
        _useAuthorization(
            from,
            validAfter,
            validBefore,
            nonce,
            keccak256(
                abi.encode(
                    SWAP_TO_LOCAL_TOKEN_WITH_AUTHORIZATION_TYPEHASH,
                    from,
                    toToken,
                    value,
                    minAmountOut,
                    maxFee,
                    validAfter,
                    validBefore,
                    nonce
                )
            ),
            signature
        );

        require(localTokens[toToken].isExists, "Target token not found");
        uint256 fee = getMetaTransactionFee();
        require(fee <= maxFee, "Fee exceeds maxFee");
        require(balanceOf(from) >= value + fee, "Not enough PCEToken balance");

        PCECommunityToken target = PCECommunityToken(toToken);
        uint256 balanceBefore = target.balanceOf(from);
        _swapToLocalToken(from, toToken, value);
        require(target.balanceOf(from) - balanceBefore >= minAmountOut, "Insufficient output amount");

        if (fee > 0) {
            _transfer(from, _msgSender(), fee);
        }
    }

    /// @dev The nonce is marked used before the signature check; a failed check reverts the whole call.
    function _useAuthorization(
        address authorizer,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes32 structHash,
        bytes memory signature
    )
        internal
    {
        require(authorizer != address(0), "Invalid authorizer address");
        require(block.timestamp > validAfter, "Not yet valid");
        require(block.timestamp < validBefore, "Authorization expired");
        require(!_authorizationStates[authorizer][nonce], "Authorization used");
        _authorizationStates[authorizer][nonce] = true;
        emit AuthorizationUsed(authorizer, nonce);
        emit AuthorizationExecuted(authorizer, nonce, structHash);

        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", EIP712.makeDomainSeparator("PCE Token", "1"), structHash));
        require(AuthorizationSignature.isValid(authorizer, digest, signature), "Invalid signature");
    }

    function getNativeTokenToPceTokenRate() public view returns (uint256) {
        return nativeTokenToPceTokenRate;
    }

    function setNativeTokenToPceTokenRate(uint160 _nativeTokenToPceTokenRate) public onlyOwner {
        nativeTokenToPceTokenRate = _nativeTokenToPceTokenRate;
    }

    function setMetaTransactionGas(uint256 _metaTransactionGas) public onlyOwner {
        metaTransactionGas = _metaTransactionGas;
    }

    function setMetaTransactionPriorityFee(uint256 _metaTransactionPriorityFee) public onlyOwner {
        metaTransactionPriorityFee = _metaTransactionPriorityFee;
    }

    function getBlockBaseFee() public view returns (uint256) {
        return block.basefee;
    }

    function getMetaTransactionFee() public view returns (uint256) {
        uint256 nativeTokenFee = metaTransactionGas * (block.basefee + metaTransactionPriorityFee);
        return Math.mulDiv(nativeTokenFee, getNativeTokenToPceTokenRate(), 2 ** 96);
    }

    function getMetaTransactionFeeWithBaseFee(uint256 _baseFee) public view returns (uint256) {
        uint256 nativeTokenFee = metaTransactionGas * (_baseFee + metaTransactionPriorityFee);
        return Math.mulDiv(nativeTokenFee, getNativeTokenToPceTokenRate(), 2 ** 96);
    }

    function hasDecreaseTimeWithin(uint256 _start, uint256 _end) public pure returns (bool) {
        return isWednesdayBetween(_start, _end);
    }

    function getElapsedMinutes(uint256 _start, uint256 _end) public pure returns (uint256) {
        require(_start <= _end, "Start time must be <= end");

        uint256 elapsedSeconds = _end - _start;
        uint256 elapsedMinutes = elapsedSeconds / 60;

        return elapsedMinutes;
    }

    /// @notice Count the number of Wednesdays strictly between start and end timestamps.
    /// Start day (if Wednesday) is excluded; the next Wednesday is the first counted.
    function countWednesdaysBetween(uint256 start, uint256 end) public pure returns (uint256) {
        uint256 startDay = start / 1 days;
        uint256 endDay = end / 1 days;
        if (startDay >= endDay) return 0;

        // Find the first Wednesday strictly after startDay
        // 0=Thursday, 1=Friday, ..., 6=Wednesday
        uint256 nextDay = startDay + 1;
        uint256 nextWeekday = nextDay % 7;
        uint256 daysToNextWed = (6 - nextWeekday + 7) % 7;
        uint256 firstWed = nextDay + daysToNextWed;

        if (firstWed > endDay) return 0;
        return ((endDay - firstWed) / 7) + 1;
    }

    function isWednesdayBetween(uint256 start, uint256 end) public pure returns (bool) {
        require(start <= end, "Start time must be <= end");
        return countWednesdaysBetween(start, end) > 0;
    }

    // for polygon bridge
    function deposit(address user, bytes calldata depositData) external {
        require(msg.sender == polygonChainManager, "Only polygon chain manager can call this function");
        uint256 amount = abi.decode(depositData, (uint256));
        _mint(user, amount);
    }

    function withdraw(uint256 amount) external {
        _burn(_msgSender(), amount);
    }

    function increaseTokenValue(address communityToken, uint256 pceAmount) external {
        require(localTokens[communityToken].isExists, "Target token not found");
        require(_msgSender() == OwnableUpgradeable(communityToken).owner(), "Only community owner");
        require(pceAmount > 0, "Amount must be > 0");

        updateFactorIfNeeded();

        uint256 oldDeposited = localTokens[communityToken].depositedPCEToken;
        uint256 oldRate = localTokens[communityToken].exchangeRate;

        _transfer(_msgSender(), address(this), pceAmount);

        // When reserves are fully drained the proportional formula collapses to zero, which would
        // brick all future swaps. Fall back to keeping the prior rate so the community can recover.
        uint256 newRate = oldDeposited == 0 ? oldRate : Math.mulDiv(oldRate, oldDeposited, oldDeposited + pceAmount);
        _syncDailyOutflow(communityToken);
        localTokens[communityToken].depositedPCEToken = oldDeposited + pceAmount;
        localTokens[communityToken].exchangeRate = newRate;

        emit TokenValueIncreased(communityToken, pceAmount, oldRate, newRate);
    }

    function splitToken(address communityToken, uint256 mintAmount) external {
        require(localTokens[communityToken].isExists, "Target token not found");
        require(_msgSender() == OwnableUpgradeable(communityToken).owner(), "Only community owner");
        require(mintAmount > 0, "Amount must be > 0");

        updateFactorIfNeeded();

        PCECommunityToken target = PCECommunityToken(communityToken);
        uint256 currentSupply = target.totalSupply();
        require(currentSupply > 0, "No supply to split");

        uint256 oldRebase = target.rebaseFactor();
        if (oldRebase == 0) oldRebase = INITIAL_FACTOR;
        uint256 newRebase = Math.mulDiv(oldRebase, currentSupply + mintAmount, currentSupply);
        target.applyRebase(newRebase);

        uint256 oldRate = localTokens[communityToken].exchangeRate;
        uint256 newRate = Math.mulDiv(oldRate, newRebase, oldRebase);
        localTokens[communityToken].exchangeRate = newRate;

        emit TokenSplit(communityToken, mintAmount, oldRate, newRate, oldRebase, newRebase);
    }

    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner { }

    function version() public pure returns (string memory) {
        return "1.0.18";
    }
}
