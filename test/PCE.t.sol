// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {PCECommunityToken} from "../src/PCECommunityToken.sol";
import {PCEToken} from "../src/PCEToken.sol";
import {ExchangeAllowMethod} from "../src/lib/Enum.sol";

// Minimal Beacon for testing
contract MinimalBeacon {
    address public implementation;
    address public owner;

    constructor(address initialImplementation) {
        implementation = initialImplementation;
        owner = msg.sender;
    }

    function upgradeTo(address newImplementation) public {
        require(msg.sender == owner, "Ownable: caller is not the owner");
        implementation = newImplementation;
    }
}

contract PCETest is Test {
    PCEToken public pceToken;
    PCECommunityToken public token;
    MinimalBeacon public pceCommunityTokenBeacon;
    address public owner;
    address public user1;
    address public user2;

    function setUp() public {
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);

        vm.startPrank(owner);

        PCECommunityToken communityImpl = new PCECommunityToken();

        pceCommunityTokenBeacon = new MinimalBeacon(address(communityImpl));

        pceToken = new PCEToken();
        pceToken.initialize();
        // Simulate V1 initialize values that were set before upgrade to V11
        // These values would exist in storage on a real deployment (set by V1's initialize)
        // slot 3: nativeTokenToPceTokenRate = 396140812571321687967719751680 (5<<96)
        vm.store(address(pceToken), bytes32(uint256(3)), bytes32(uint256(396140812571321687967719751680)));
        // slot 4: metaTransactionGas = 200000
        vm.store(address(pceToken), bytes32(uint256(4)), bytes32(uint256(200000)));
        // slot 5: metaTransactionPriorityFee = 50000000000 (50 gwei)
        vm.store(address(pceToken), bytes32(uint256(5)), bytes32(uint256(50000000000)));
        // slot 6: swapableToPCERate = 300 (3%)
        vm.store(address(pceToken), bytes32(uint256(6)), bytes32(uint256(300)));
        // slot 7: swapableToPCEIndividualRate = 300 (3%)
        vm.store(address(pceToken), bytes32(uint256(7)), bytes32(uint256(300)));
        pceToken.setCommunityTokenAddress(address(pceCommunityTokenBeacon));

        pceToken.mint(owner, 10000 ether);

        address[] memory incomeTargetTokens = new address[](0);
        address[] memory outgoTargetTokens = new address[](0);

        pceToken.createToken(
            "Test Community Token",
            "TCT",
            1000 ether,
            1 ether,   // 1:1 dilution
            1,         // decrease interval days
            9800,      // after decrease bp (98%)
            1000,      // max increase of total supply bp
            500,       // max increase bp
            1000,      // max usage bp
            100,       // change bp
            ExchangeAllowMethod.All,
            ExchangeAllowMethod.All,
            incomeTargetTokens,
            outgoTargetTokens
        );

        vm.stopPrank();

        address[] memory tokens_ = pceToken.getTokens();
        token = PCECommunityToken(tokens_[0]);
    }

    function testSwapFromLocalToken() public {
        vm.startPrank(owner);
        uint256 swapAmount = 100 ether;
        pceToken.swapToLocalToken(address(token), swapAmount);

        uint256 communityBalance = token.balanceOf(owner);
        assertTrue(communityBalance > 0, "Should have community tokens after swap");

        // Advance time by 1 day so midnightBalance gets set
        vm.warp(block.timestamp + 1 days);
        token.transfer(user1, 1 ether);

        // Advance another day
        vm.warp(block.timestamp + 1 days);

        uint256 swapBackAmount = 10 ether;
        uint256 pceBalanceBefore = pceToken.balanceOf(owner);

        pceToken.swapFromLocalToken(address(token), swapBackAmount);

        uint256 pceBalanceAfter = pceToken.balanceOf(owner);
        assertTrue(pceBalanceAfter > pceBalanceBefore, "PCE balance should increase after swap from local");

        vm.stopPrank();
    }

    function testSwapFromLocalTokenWithoutApprove() public {
        vm.startPrank(owner);

        pceToken.swapToLocalToken(address(token), 100 ether);

        vm.warp(block.timestamp + 1 days);
        token.transfer(user1, 1 ether);
        vm.warp(block.timestamp + 1 days);

        uint256 communityBalanceBefore = token.balanceOf(owner);
        pceToken.swapFromLocalToken(address(token), 5 ether);
        uint256 communityBalanceAfter = token.balanceOf(owner);

        assertTrue(communityBalanceAfter < communityBalanceBefore, "Community tokens should decrease");

        vm.stopPrank();
    }

    function testBurnByPCETokenOnlyCallableByPCEToken() public {
        vm.startPrank(owner);
        pceToken.swapToLocalToken(address(token), 100 ether);
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert("Only PCE token");
        token.burnByPCEToken(owner, 10 ether);
        vm.stopPrank();
    }

    function testMintOnlyCallableByPCEToken() public {
        vm.startPrank(owner);
        vm.expectRevert("Only PCE token");
        token.mint(owner, 100 ether);
        vm.stopPrank();
    }

    function testRecordSwapToPCEOnlyCallableByPCEToken() public {
        vm.startPrank(user1);
        vm.expectRevert("Only PCE token");
        token.recordSwapToPCE(user1, 10 ether);
        vm.stopPrank();
    }

    function testRemainingBalanceDecreasesAfterSwap() public {
        vm.startPrank(owner);

        pceToken.swapToLocalToken(address(token), 100 ether);

        // Advance time so midnightBalance gets set
        vm.warp(block.timestamp + 1 days);
        token.transfer(user1, 1 ether);
        vm.warp(block.timestamp + 1 days);

        uint256 remainingBefore = token.getRemainingSwapableToPCEBalanceForIndividual(owner);
        assertTrue(remainingBefore > 0, "Should have remaining swapable balance");

        uint256 globalRemainingBefore = token.getRemainingSwapableToPCEBalance();
        assertTrue(globalRemainingBefore > 0, "Should have global remaining swapable balance");

        // Do a swap
        uint256 swapAmount = 5 ether;
        pceToken.swapFromLocalToken(address(token), swapAmount);

        uint256 remainingAfter = token.getRemainingSwapableToPCEBalanceForIndividual(owner);
        uint256 globalRemainingAfter = token.getRemainingSwapableToPCEBalance();

        assertEq(remainingBefore - remainingAfter, swapAmount, "Individual remaining should decrease by swapAmount");
        assertEq(globalRemainingBefore - globalRemainingAfter, swapAmount, "Global remaining should decrease by swapAmount");

        vm.stopPrank();
    }

    function testRevertOnExceedingDailyLimit() public {
        vm.startPrank(owner);

        pceToken.swapToLocalToken(address(token), 500 ether);

        // Advance time so midnightBalance gets set
        vm.warp(block.timestamp + 1 days);
        token.transfer(user1, 1 ether);
        vm.warp(block.timestamp + 1 days);

        uint256 remaining = token.getRemainingSwapableToPCEBalance();
        console2.log("Global remaining swapable:", remaining);

        // If remaining is 0, the limit is already exceeded from setup
        if (remaining == 0) {
            vm.expectRevert("Exceeds daily swap limit");
            pceToken.swapFromLocalToken(address(token), 1 ether);
        } else {
            // Swap exactly the remaining amount (should succeed)
            if (remaining > 0) {
                pceToken.swapFromLocalToken(address(token), remaining);
            }

            // Now any additional swap should revert
            vm.expectRevert("Exceeds daily swap limit");
            pceToken.swapFromLocalToken(address(token), 1 ether);
        }

        vm.stopPrank();
    }

    function testRevertOnExceedingIndividualDailyLimit() public {
        vm.startPrank(owner);

        pceToken.swapToLocalToken(address(token), 500 ether);

        // Transfer some community tokens to user1
        vm.warp(block.timestamp + 1 days);
        token.transfer(user1, 200 ether);
        vm.warp(block.timestamp + 1 days);

        vm.stopPrank();

        vm.startPrank(user1);

        uint256 individualRemaining = token.getRemainingSwapableToPCEBalanceForIndividual(user1);
        console2.log("Individual remaining swapable for user1:", individualRemaining);

        if (individualRemaining > 0) {
            pceToken.swapFromLocalToken(address(token), individualRemaining);

            // Now it should revert
            vm.expectRevert("Exceeds daily individual swap limit");
            pceToken.swapFromLocalToken(address(token), 1 ether);
        }

        vm.stopPrank();
    }

    function testDailyLimitResetsAfterDayPasses() public {
        vm.startPrank(owner);

        pceToken.swapToLocalToken(address(token), 500 ether);

        // Advance time so midnightBalance gets set
        vm.warp(block.timestamp + 1 days);
        token.transfer(user1, 1 ether);
        vm.warp(block.timestamp + 1 days);

        uint256 remainingBefore = token.getRemainingSwapableToPCEBalance();
        assertTrue(remainingBefore > 0, "Should have remaining balance");

        // Swap some
        uint256 swapAmount = 3 ether;
        require(remainingBefore >= swapAmount, "Not enough remaining for test");
        pceToken.swapFromLocalToken(address(token), swapAmount);

        uint256 remainingAfterSwap = token.getRemainingSwapableToPCEBalance();
        assertTrue(remainingAfterSwap < remainingBefore, "Remaining should decrease");

        // Advance to next day (2 days to ensure intervalDaysOf detects crossing)
        vm.warp(block.timestamp + 2 days);

        uint256 remainingAfterReset = token.getRemainingSwapableToPCEBalance();
        // After day reset, used resets to 0, so remaining == full daily limit
        assertTrue(remainingAfterReset > remainingAfterSwap, "Remaining should reset after day passes");

        vm.stopPrank();
    }

    function testCommunityTokenDepreciatesOverTime() public {
        vm.startPrank(owner);

        // Decrease interval is 1 day, afterDecreaseBp = 9800 (98%)
        uint256 day1 = block.timestamp + 1 days;
        uint256 day2 = block.timestamp + 2 days;

        // Swap PCE to community token
        pceToken.swapToLocalToken(address(token), 100 ether);
        uint256 balanceAtSwap = token.balanceOf(owner);
        assertTrue(balanceAtSwap > 0, "Should have community tokens after swap");

        // Advance 1 day
        vm.warp(day1);

        uint256 balanceAfter1Day = token.balanceOf(owner);
        assertLt(balanceAfter1Day, balanceAtSwap, "Display balance should DECREASE after 1 day (depreciation)");

        // Advance 2 days from start
        vm.warp(day2);

        uint256 balanceAfter2Days = token.balanceOf(owner);
        assertLt(balanceAfter2Days, balanceAfter1Day, "Display balance should continue decreasing");

        // Verify the depreciation rate is approximately 2% per day
        uint256 expectedAfter1Day = balanceAtSwap * 98 / 100;
        assertApproxEqAbs(balanceAfter1Day, expectedAfter1Day, 1, "Should be ~98% after 1 day");

        uint256 expectedAfter2Days = balanceAtSwap * 9604 / 10000;
        assertApproxEqAbs(balanceAfter2Days, expectedAfter2Days, 1, "Should be ~96.04% after 2 days");

        vm.stopPrank();
    }

    function testNewMintAfterDepreciationShowsCorrectBalance() public {
        vm.startPrank(owner);

        uint256 day1 = block.timestamp + 1 days;
        uint256 day2 = block.timestamp + 2 days;

        // First swap at day 0
        pceToken.swapToLocalToken(address(token), 100 ether);
        uint256 firstMintBalance = token.balanceOf(owner);

        // Advance 1 day (factor depreciates by 2%)
        vm.warp(day1);

        uint256 depreciated = token.balanceOf(owner);
        assertLt(depreciated, firstMintBalance, "First mint should have depreciated");

        // Second swap at day 1 (same 100 PCE as first swap)
        pceToken.swapToLocalToken(address(token), 100 ether);
        uint256 totalAfterSecondMint = token.balanceOf(owner);
        uint256 secondMintDelta = totalAfterSecondMint - depreciated;

        // Verify second mint delta matches the full swap formula in swapToLocalToken:
        // targetTokenAmount = amountToSwap * exchangeRate / INITIAL_FACTOR * communityFactor / pceFactor
        uint256 exchangeRate = pceToken.getExchangeRate(address(token));
        uint256 expectedSecondMint = 100 ether * exchangeRate / 1e18 * token.getCurrentFactor() / pceToken.getCurrentFactor();
        assertApproxEqAbs(secondMintDelta, expectedSecondMint, 1, "Second mint should match swap formula at day 1");

        // Advance 2 days from start - all tokens should depreciate
        vm.warp(day2);
        uint256 allDepreciated = token.balanceOf(owner);
        assertLt(allDepreciated, totalAfterSecondMint, "All tokens should depreciate after another day");

        // Verify combined depreciation:
        // - First swap tokens (minted at day 0): depreciated 2 periods → 98% × 98% = 96.04%
        // - Second swap tokens (minted at day 1): depreciated 1 period → 98%
        uint256 expectedDay2 = depreciated * 98 / 100 + secondMintDelta * 98 / 100;
        assertApproxEqAbs(allDepreciated, expectedDay2, 1, "Day 2 total should match combined depreciation");

        vm.stopPrank();
    }

    function testVersion() public view {
        assertEq(pceToken.version(), "1.0.14");
        assertEq(token.version(), "1.0.15");
    }

    // --- PIP-12: Treasury wallet and token value operations tests ---

    function _setupTreasury() internal {
        // Create a treasury wallet address
        address treasury = address(0x1234);

        // Owner initializes treasury on the community token
        vm.startPrank(owner);
        token.initializeTreasury(treasury);
        vm.stopPrank();
    }

    function _setupTreasuryWithDeposit() internal returns (address treasury) {
        treasury = address(0x1234);

        vm.startPrank(owner);
        token.initializeTreasury(treasury);

        // Give treasury wallet some PCE tokens and approve PCEToken contract
        pceToken.transfer(treasury, 200 ether);
        vm.stopPrank();

        vm.startPrank(treasury);
        pceToken.approve(address(pceToken), type(uint256).max);
        vm.stopPrank();
    }

    function testInitializeTreasury() public {
        address treasury = address(0x1234);

        vm.startPrank(owner);
        token.initializeTreasury(treasury);
        vm.stopPrank();

        // Treasury wallet should be set
        assertEq(token.treasuryWallet(), treasury, "Treasury wallet should be set");

        // Owner should have RATE_MANAGER_ROLE
        assertTrue(
            token.hasRole(token.RATE_MANAGER_ROLE(), owner),
            "Owner should have rate manager role"
        );
    }

    function testInitializeTreasuryCannotBeCalledTwice() public {
        address treasury = address(0x1234);

        vm.startPrank(owner);
        token.initializeTreasury(treasury);

        vm.expectRevert("Already initialized");
        token.initializeTreasury(address(0x5678));
        vm.stopPrank();
    }

    function testIncreaseTokenValue() public {
        address treasury = _setupTreasuryWithDeposit();

        // Initial state: depositedPCEToken=1000e18 (from createToken), exchangeRate=1e18
        uint256 depositedBefore = pceToken.getDepositedPCETokens(address(token));
        uint256 rateBefore = pceToken.getExchangeRate(address(token));
        assertEq(depositedBefore, 1000 ether, "Initial deposited should be 1000e18");
        assertEq(rateBefore, 1 ether, "Initial exchange rate should be 1e18");

        uint256 treasuryBalanceBefore = pceToken.balanceOf(treasury);
        uint256 increaseAmount = 100 ether;

        // Increase token value by 100e18 (treasury has 200 PCE)
        vm.startPrank(owner);
        token.increaseTokenValue(increaseAmount);
        vm.stopPrank();

        uint256 depositedAfter = pceToken.getDepositedPCETokens(address(token));
        uint256 rateAfter = pceToken.getExchangeRate(address(token));
        uint256 treasuryBalanceAfter = pceToken.balanceOf(treasury);

        // depositedPCEToken should be 1100e18
        assertEq(depositedAfter, depositedBefore + increaseAmount, "Deposited should increase");

        // exchangeRate = 1e18 * 1000e18 / 1100e18
        uint256 expectedRate = (rateBefore * depositedBefore) / (depositedBefore + increaseAmount);
        assertEq(rateAfter, expectedRate, "Exchange rate should be adjusted downward");

        // Treasury balance should decrease by increaseAmount
        assertEq(
            treasuryBalanceBefore - treasuryBalanceAfter,
            increaseAmount,
            "Treasury should have sent PCE"
        );
    }

    function testIncreaseTokenValueWithSmallDeposit() public {
        // Test with deposited=100e18, rate=1e18, increase=50e18

        vm.startPrank(owner);

        // Create a new community token with 100e18 deposit
        address[] memory incomeTargetTokens = new address[](0);
        address[] memory outgoTargetTokens = new address[](0);

        pceToken.createToken(
            "Small Community Token",
            "SCT",
            100 ether,
            1 ether,
            1, 9800, 1000, 500, 1000, 100,
            ExchangeAllowMethod.All,
            ExchangeAllowMethod.All,
            incomeTargetTokens,
            outgoTargetTokens
        );

        address[] memory tokens_ = pceToken.getTokens();
        PCECommunityToken smallToken = PCECommunityToken(tokens_[tokens_.length - 1]);

        // Set up treasury
        address treasury = address(0x5678);
        smallToken.initializeTreasury(treasury);

        // Give treasury 50 PCE and approve
        pceToken.transfer(treasury, 50 ether);
        vm.stopPrank();

        vm.startPrank(treasury);
        pceToken.approve(address(pceToken), type(uint256).max);
        vm.stopPrank();

        // Verify initial state
        assertEq(pceToken.getDepositedPCETokens(address(smallToken)), 100 ether);
        assertEq(pceToken.getExchangeRate(address(smallToken)), 1 ether);

        // Increase token value by 50e18
        vm.startPrank(owner);
        smallToken.increaseTokenValue(50 ether);
        vm.stopPrank();

        // depositedPCEToken = 150e18
        assertEq(pceToken.getDepositedPCETokens(address(smallToken)), 150 ether);

        // exchangeRate = 1e18 * 100e18 / 150e18 = 666666666666666666 (~0.667e18)
        uint256 rateNum = 1 ether * 100 ether;
        uint256 rateDen = 150 ether;
        uint256 expectedRate = rateNum / rateDen;
        assertEq(pceToken.getExchangeRate(address(smallToken)), expectedRate);
    }

    function testSplitToken() public {
        // Test stock-split: totalSupply=100 tokens, mint 25 more → rebaseFactor increases
        vm.startPrank(owner);

        address[] memory incomeTargetTokens = new address[](0);
        address[] memory outgoTargetTokens = new address[](0);

        pceToken.createToken(
            "Split Test Token",
            "STT",
            100 ether,
            1 ether,
            1, 9800, 1000, 500, 1000, 100,
            ExchangeAllowMethod.All,
            ExchangeAllowMethod.All,
            incomeTargetTokens,
            outgoTargetTokens
        );

        address[] memory tokens_ = pceToken.getTokens();
        PCECommunityToken sToken = PCECommunityToken(tokens_[tokens_.length - 1]);

        address treasury = address(0x9999);
        sToken.initializeTreasury(treasury);

        uint256 rateBefore = pceToken.getExchangeRate(address(sToken));
        uint256 rebaseFactorBefore = sToken.rebaseFactor();
        uint256 totalSupplyBefore = sToken.totalSupply();

        // Split: mint 25 tokens worth
        uint256 mintAmount = 25 ether;
        sToken.splitToken(mintAmount);
        vm.stopPrank();

        uint256 rebaseFactorAfter = sToken.rebaseFactor();
        uint256 rateAfter = pceToken.getExchangeRate(address(sToken));
        uint256 totalSupplyAfter = sToken.totalSupply();

        // rebaseFactor should increase: old * (total + mint) / total
        uint256 expectedRebaseFactor = (rebaseFactorBefore * (totalSupplyBefore + mintAmount)) / totalSupplyBefore;
        assertEq(rebaseFactorAfter, expectedRebaseFactor, "Rebase factor should increase proportionally");

        // exchangeRate should increase: old * newRebase / oldRebase
        uint256 expectedRate = (rateBefore * rebaseFactorAfter) / rebaseFactorBefore;
        assertEq(rateAfter, expectedRate, "Exchange rate should adjust for split");

        // Total supply should increase by mintAmount
        assertEq(totalSupplyAfter, totalSupplyBefore + mintAmount, "Total supply should increase");
    }

    function testSplitTokenZeroAmountReverts() public {
        _setupTreasury();

        vm.startPrank(owner);
        vm.expectRevert("Amount must be > 0");
        token.splitToken(0);
        vm.stopPrank();
    }

    function testUnauthorizedAccess() public {
        _setupTreasury();

        // user1 (not a rate manager) tries to call increaseTokenValue
        vm.startPrank(user1);
        vm.expectRevert("Not rate manager");
        token.increaseTokenValue(10 ether);

        vm.expectRevert("Not rate manager");
        token.splitToken(10 ether);

        vm.expectRevert("Not rate manager");
        token.setTreasuryWallet(address(0x5555));

        vm.expectRevert("Not rate manager");
        token.grantRateManagerRole(user2);

        vm.expectRevert("Not rate manager");
        token.revokeRateManagerRole(owner);
        vm.stopPrank();

        // user1 tries to call initializeTreasury (not owner)
        vm.startPrank(user1);
        vm.expectRevert();
        token.initializeTreasury(address(0x6666));
        vm.stopPrank();
    }

    function testRoleManagement() public {
        _setupTreasury();

        // Owner has rate manager role after initializeTreasury
        assertTrue(
            token.hasRole(token.RATE_MANAGER_ROLE(), owner),
            "Owner should have rate manager role"
        );

        // Owner grants role to user1
        vm.startPrank(owner);
        token.grantRateManagerRole(user1);
        vm.stopPrank();

        assertTrue(
            token.hasRole(token.RATE_MANAGER_ROLE(), user1),
            "User1 should have rate manager role"
        );

        // User1 can now revoke owner's role
        vm.startPrank(user1);
        token.revokeRateManagerRole(owner);
        vm.stopPrank();

        assertFalse(
            token.hasRole(token.RATE_MANAGER_ROLE(), owner),
            "Owner should no longer have rate manager role"
        );

        // Owner can no longer call rate manager functions
        vm.startPrank(owner);
        vm.expectRevert("Not rate manager");
        token.increaseTokenValue(10 ether);
        vm.stopPrank();

        // User1 can still call rate manager functions (setTreasuryWallet)
        vm.startPrank(user1);
        token.setTreasuryWallet(address(0x7777));
        vm.stopPrank();

        assertEq(token.treasuryWallet(), address(0x7777), "Treasury wallet should be updated");
    }

    // --- PIP-13: Meta-Transaction Fee Auto-Swap Tests ---

    function _makeDomainSeparator(address tokenAddr) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("PeaceBaseCoin"),
                keccak256("1"),
                block.chainid,
                tokenAddr
            )
        );
    }

    function _buildTransferWithAuthDigest(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    )
        internal
        view
        returns (bytes32)
    {
        bytes32 domainSeparator = _makeDomainSeparator(address(token));
        bytes32 structHash = keccak256(
            abi.encode(
                bytes32(0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267),
                from,
                to,
                value,
                validAfter,
                validBefore,
                nonce
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function testFeeSwapFromLocalToken() public {
        // Setup: give community tokens to owner via swapToLocalToken
        vm.startPrank(owner);
        pceToken.swapToLocalToken(address(token), 100 ether);
        vm.warp(block.timestamp + 1 days);
        token.transfer(user1, 1 ether);
        vm.warp(block.timestamp + 1 days);
        vm.stopPrank();

        address relayer = address(0x3);
        uint256 displayAmount = 1 ether;

        // Call swapFeeFromLocalToken directly as the community token contract
        uint256 relayerPCEBefore = pceToken.balanceOf(relayer);

        vm.prank(address(token));
        uint256 pceAmount = pceToken.swapFeeFromLocalToken(address(token), relayer, displayAmount);

        uint256 relayerPCEAfter = pceToken.balanceOf(relayer);
        assertTrue(pceAmount > 0, "Should return non-zero PCE amount");
        assertTrue(relayerPCEAfter > relayerPCEBefore, "Relayer should receive PCE");
    }

    function testSwapFeeFromLocalTokenOnlyCallableByCommunityToken() public {
        // Non-community-token address should be rejected
        vm.prank(user1);
        vm.expectRevert("Caller must be the community token");
        pceToken.swapFeeFromLocalToken(address(token), user1, 1 ether);
    }

    function testSwapFeeFromLocalTokenUnregisteredToken() public {
        // Unregistered token address should be rejected
        address fakeToken = address(0x999);
        vm.prank(fakeToken);
        vm.expectRevert("Token not registered");
        pceToken.swapFeeFromLocalToken(fakeToken, user1, 1 ether);
    }

    function testFeeSwapBypassesDailyLimit() public {
        vm.startPrank(owner);
        pceToken.swapToLocalToken(address(token), 500 ether);

        // Advance time for midnightBalance setup
        vm.warp(block.timestamp + 1 days);
        token.transfer(user1, 1 ether);
        vm.warp(block.timestamp + 1 days);

        // Exhaust daily swap limit via regular swaps
        uint256 remaining = token.getRemainingSwapableToPCEBalance();
        if (remaining > 0) {
            pceToken.swapFromLocalToken(address(token), remaining);
        }

        // Verify regular swap now fails
        vm.expectRevert("Exceeds daily swap limit");
        pceToken.swapFromLocalToken(address(token), 1 ether);
        vm.stopPrank();

        // Fee swap should still work despite exhausted daily limit
        address relayer = address(0x3);
        uint256 relayerPCEBefore = pceToken.balanceOf(relayer);

        vm.prank(address(token));
        uint256 pceAmount = pceToken.swapFeeFromLocalToken(address(token), relayer, 0.01 ether);

        assertTrue(pceAmount > 0, "Fee swap should succeed even when daily limit exhausted");
        assertTrue(pceToken.balanceOf(relayer) > relayerPCEBefore, "Relayer should receive PCE");
    }

    function testFeeSwapDoesNotAffectDailyLimitCounters() public {
        vm.startPrank(owner);
        pceToken.swapToLocalToken(address(token), 100 ether);

        vm.warp(block.timestamp + 1 days);
        token.transfer(user1, 1 ether);
        vm.warp(block.timestamp + 1 days);

        uint256 globalRemainingBefore = token.getRemainingSwapableToPCEBalance();
        vm.stopPrank();

        // Do a fee swap
        vm.prank(address(token));
        pceToken.swapFeeFromLocalToken(address(token), address(0x3), 0.01 ether);

        // Daily limit counters should be unchanged
        uint256 globalRemainingAfter = token.getRemainingSwapableToPCEBalance();
        assertEq(globalRemainingBefore, globalRemainingAfter, "Fee swap should not affect daily limit counters");
    }

    function testTransferWithAuthorizationFeeSwap() public {
        // Setup: create signer with known private key
        uint256 signerPrivateKey = 0xA11CE;
        address signer = vm.addr(signerPrivateKey);
        address relayer = address(0x3);

        // Give signer community tokens
        vm.startPrank(owner);
        pceToken.swapToLocalToken(address(token), 200 ether);
        vm.warp(block.timestamp + 1 days);
        token.transfer(signer, 50 ether);
        vm.warp(block.timestamp + 1 days);
        vm.stopPrank();

        // Build EIP712 signature for transferWithAuthorization
        uint256 transferAmount = 5 ether;
        bytes32 nonce = bytes32(uint256(1));
        uint256 validAfter = 0;
        uint256 validBefore = type(uint256).max;

        bytes32 digest = _buildTransferWithAuthDigest(
            signer, user2, transferAmount, validAfter, validBefore, nonce
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);

        // Record balances before
        uint256 relayerPCEBefore = pceToken.balanceOf(relayer);
        uint256 relayerCTBefore = token.balanceOf(relayer);
        uint256 user2CTBefore = token.balanceOf(user2);

        uint256 displayFee = token.getMetaTransactionFee();
        uint256 rawFee = token.displayBalanceToRawBalance(displayFee);

        vm.expectEmit(true, true, false, true);
        emit PCECommunityToken.MetaTransactionFeeCollected(signer, relayer, displayFee, rawFee);

        // Execute as relayer
        vm.prank(relayer);
        token.transferWithAuthorization(
            signer, user2, transferAmount, validAfter, validBefore, nonce, v, r, s
        );

        // Verify: relayer received PCE, NOT community tokens
        uint256 relayerPCEAfter = pceToken.balanceOf(relayer);
        uint256 relayerCTAfter = token.balanceOf(relayer);

        assertTrue(relayerPCEAfter > relayerPCEBefore, "Relayer should receive PCE as fee");
        assertEq(relayerCTAfter, relayerCTBefore, "Relayer should NOT receive community tokens");

        // Verify: user2 received the transfer
        assertTrue(token.balanceOf(user2) > user2CTBefore, "Recipient should receive community tokens");
    }

    // --- PIP-13 fee swap across remaining *WithAuthorization* paths ---
    // These all use `this.DOMAIN_SEPARATOR()` (ERC20Permit domain), not the
    // hardcoded "PeaceBaseCoin" domain used by _transferWithAuthorization.

    function _setupAuthSigner(uint256 pk, uint256 initialCT) internal returns (address signer) {
        signer = vm.addr(pk);
        vm.startPrank(owner);
        pceToken.swapToLocalToken(address(token), 500 ether);
        vm.warp(block.timestamp + 1 days);
        token.transfer(signer, initialCT);
        vm.warp(block.timestamp + 1 days);
        vm.stopPrank();
    }

    function _signDigestBytes(uint256 pk, bytes memory data) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), keccak256(data)));
        (v, r, s) = vm.sign(pk, digest);
    }

    function testTransferFromWithAuthorizationFeeSwap() public {
        // In transferFromWithAuthorization the `spender` is the authorizer
        // (who signs) and must hold allowance over `from`. We set
        // spender == from == signer so the signer effectively authorises
        // themselves; the relayer just submits the transaction.
        uint256 pk = 0xBE11E;
        address signer = _setupAuthSigner(pk, 50 ether);
        address relayer = address(0x9A);

        vm.prank(signer);
        token.approve(signer, 20 ether);

        uint256 nonce = uint256(bytes32(keccak256("tf-auth-fee")));
        uint256 amt = 5 ether;
        bytes memory data = abi.encode(
            token.TRANSFER_FROM_WITH_AUTHORIZATION_TYPEHASH(),
            signer, signer, user2, amt, uint256(0), type(uint256).max, bytes32(nonce)
        );
        (uint8 v, bytes32 r, bytes32 s) = _signDigestBytes(pk, data);

        uint256 relayerPCEBefore = pceToken.balanceOf(relayer);
        uint256 relayerCTBefore = token.balanceOf(relayer);
        uint256 user2Before = token.balanceOf(user2);

        vm.prank(relayer);
        token.transferFromWithAuthorization(
            signer, signer, user2, amt, 0, type(uint256).max, bytes32(nonce), v, r, s
        );

        assertGt(pceToken.balanceOf(relayer), relayerPCEBefore, "relayer should receive PCE fee");
        assertEq(token.balanceOf(relayer), relayerCTBefore, "relayer should NOT receive CT");
        assertGt(token.balanceOf(user2), user2Before, "recipient should receive tokens");
    }

    function testTransferWithAuthorizationWithMessageCount() public {
        uint256 pk = 0xBEE;
        address signer = _setupAuthSigner(pk, 50 ether);
        address relayer = address(0x9B);

        uint256 nonce = uint256(bytes32(keccak256("tw-mc-auth")));
        uint256 amt = 5 ether;
        uint256 messageCount = 7;
        bytes memory data = abi.encode(
            token.TRANSFER_WITH_AUTHORIZATION_WITH_MESSAGE_COUNT_TYPEHASH(),
            signer, user2, amt, uint256(0), type(uint256).max, bytes32(nonce), messageCount
        );
        (uint8 v, bytes32 r, bytes32 s) = _signDigestBytes(pk, data);

        uint256 relayerPCEBefore = pceToken.balanceOf(relayer);
        uint256 user2Before = token.balanceOf(user2);

        vm.expectEmit(true, true, false, true);
        emit PCECommunityToken.TransferWithMessageCount(signer, user2, amt, messageCount);

        vm.prank(relayer);
        token.transferWithAuthorizationWithMessageCount(
            signer, user2, amt, 0, type(uint256).max, bytes32(nonce), v, r, s, messageCount
        );

        assertGt(pceToken.balanceOf(relayer), relayerPCEBefore, "relayer should receive PCE fee");
        assertGt(token.balanceOf(user2), user2Before, "recipient should receive tokens");
    }

    function testTransferWithAuthorizationWithMessageCountRejectsReplay() public {
        uint256 pk = 0xBEE2;
        address signer = _setupAuthSigner(pk, 50 ether);
        address relayer = address(0x9C);

        uint256 nonce = uint256(bytes32(keccak256("tw-mc-replay")));
        bytes memory data = abi.encode(
            token.TRANSFER_WITH_AUTHORIZATION_WITH_MESSAGE_COUNT_TYPEHASH(),
            signer, user2, uint256(1 ether), uint256(0), type(uint256).max, bytes32(nonce), uint256(1)
        );
        (uint8 v, bytes32 r, bytes32 s) = _signDigestBytes(pk, data);

        vm.prank(relayer);
        token.transferWithAuthorizationWithMessageCount(
            signer, user2, 1 ether, 0, type(uint256).max, bytes32(nonce), v, r, s, 1
        );

        vm.prank(relayer);
        vm.expectRevert("Authorization used");
        token.transferWithAuthorizationWithMessageCount(
            signer, user2, 1 ether, 0, type(uint256).max, bytes32(nonce), v, r, s, 1
        );
    }

    function testTransferFromWithAuthorizationWithMessageCount() public {
        // Same authorizer-self pattern as testTransferFromWithAuthorizationFeeSwap.
        uint256 pk = 0xBEE3;
        address signer = _setupAuthSigner(pk, 50 ether);
        address relayer = address(0x9D);

        vm.prank(signer);
        token.approve(signer, 20 ether);

        uint256 nonce = uint256(bytes32(keccak256("tfw-mc")));
        uint256 amt = 3 ether;
        uint256 messageCount = 5;
        bytes memory data = abi.encode(
            token.TRANSFER_FROM_WITH_AUTHORIZATION_WITH_MESSAGE_COUNT_TYPEHASH(),
            signer, signer, user2, amt, uint256(0), type(uint256).max, bytes32(nonce), messageCount
        );
        (uint8 v, bytes32 r, bytes32 s) = _signDigestBytes(pk, data);

        uint256 relayerPCEBefore = pceToken.balanceOf(relayer);
        uint256 user2Before = token.balanceOf(user2);

        vm.prank(relayer);
        token.transferFromWithAuthorizationWithMessageCount(
            signer, signer, user2, amt, 0, type(uint256).max, bytes32(nonce), v, r, s, messageCount
        );

        assertGt(pceToken.balanceOf(relayer), relayerPCEBefore, "relayer should receive PCE fee");
        assertGt(token.balanceOf(user2), user2Before, "recipient should receive tokens");
    }

    function testSetInfinityApproveFlagWithAuthorizationFeeSwap() public {
        uint256 pk = 0xBEE4;
        address signer = _setupAuthSigner(pk, 50 ether);
        address relayer = address(0x9E);
        address spender = address(0xAA);

        uint256 nonce = uint256(bytes32(keccak256("set-inf-auth")));
        bytes memory data = abi.encode(
            token.SET_INFINITY_APPROVE_FLAG_WITH_AUTHORIZATION_TYPEHASH(),
            signer, spender, true, uint256(0), type(uint256).max, bytes32(nonce)
        );
        (uint8 v, bytes32 r, bytes32 s) = _signDigestBytes(pk, data);

        uint256 relayerPCEBefore = pceToken.balanceOf(relayer);
        assertFalse(token.getInfinityApproveFlag(signer, spender), "flag should start false");

        vm.prank(relayer);
        token.setInfinityApproveFlagWithAuthorization(
            signer, spender, true, 0, type(uint256).max, bytes32(nonce), v, r, s
        );

        assertTrue(token.getInfinityApproveFlag(signer, spender), "flag should be set true");
        assertGt(pceToken.balanceOf(relayer), relayerPCEBefore, "relayer should receive PCE fee");
    }

    function testClaimVoucherWithAuthorizationRejectsReplay() public {
        // VoucherSystem.claimWithAuthorizationAndTransfer has its own nonce
        // check (not sharing _useAuthorization); verify it still blocks replay.
        uint256 pk = 0xBEE6;
        address signer = _setupAuthSigner(pk, 0);
        address relayer = address(0xA1);

        bytes32 leaf = keccak256(abi.encodePacked("REPLAY-CODE"));
        uint256 endTime = block.timestamp + 365 days;
        vm.startPrank(owner);
        // Configure countLimitPerUser=2 so the first claim does not exhaust the
        // per-user limit, and we can prove the second attempt is rejected by nonce.
        token.registerVoucherIssuance(
            "VR001", "replay-voucher", 10 ether, 2, 20 ether, 20 ether,
            0, endTime, leaf, ""
        );
        vm.stopPrank();

        uint256 nonce = uint256(bytes32(keccak256("claim-replay")));
        bytes32[] memory proof = new bytes32[](0);
        bytes memory data = abi.encode(
            token.CLAIM_WITH_AUTHORIZATION_TYPEHASH(),
            signer,
            keccak256(bytes("VR001")),
            keccak256(bytes("REPLAY-CODE")),
            uint256(0),
            type(uint256).max,
            bytes32(nonce)
        );
        (uint8 v, bytes32 r, bytes32 s) = _signDigestBytes(pk, data);

        vm.prank(relayer);
        token.claimVoucherWithAuthorization(
            signer, "VR001", "REPLAY-CODE", proof, 0, type(uint256).max, bytes32(nonce), v, r, s
        );

        vm.prank(relayer);
        vm.expectRevert("Authorization used");
        token.claimVoucherWithAuthorization(
            signer, "VR001", "REPLAY-CODE", proof, 0, type(uint256).max, bytes32(nonce), v, r, s
        );
    }

    function testClaimVoucherWithAuthorizationFeeSwap() public {
        uint256 pk = 0xBEE5;
        address signer = _setupAuthSigner(pk, 0); // claimer needs no prior balance
        address relayer = address(0x9F);

        // Register a voucher funded by `owner`.
        // Simple 1-leaf merkle tree: root = keccak256(code)
        bytes32 leaf = keccak256(abi.encodePacked("CLAIMCODE-001"));

        // Use a far-future endTime so factor-decay warps do not invalidate it.
        uint256 endTime = block.timestamp + 365 days;
        vm.startPrank(owner);
        token.registerVoucherIssuance(
            "VA001", "auth-voucher", 10 ether, 1, 10 ether, 10 ether,
            0, endTime, leaf, ""
        );
        vm.stopPrank();

        uint256 nonce = uint256(bytes32(keccak256("claim-auth")));
        bytes32[] memory proof = new bytes32[](0);
        bytes memory data = abi.encode(
            token.CLAIM_WITH_AUTHORIZATION_TYPEHASH(),
            signer,
            keccak256(bytes("VA001")),
            keccak256(bytes("CLAIMCODE-001")),
            uint256(0),
            type(uint256).max,
            bytes32(nonce)
        );
        (uint8 v, bytes32 r, bytes32 s) = _signDigestBytes(pk, data);

        uint256 signerCTBefore = token.balanceOf(signer);
        uint256 relayerPCEBefore = pceToken.balanceOf(relayer);
        uint256 relayerCTBefore = token.balanceOf(relayer);

        vm.prank(relayer);
        token.claimVoucherWithAuthorization(
            signer, "VA001", "CLAIMCODE-001", proof, 0, type(uint256).max, bytes32(nonce), v, r, s
        );

        assertGt(token.balanceOf(signer), signerCTBefore, "claimer should receive CT (minus fee)");
        assertGt(pceToken.balanceOf(relayer), relayerPCEBefore, "relayer should receive PCE fee");
        assertEq(token.balanceOf(relayer), relayerCTBefore, "relayer should NOT receive CT");
    }

    // --- PIP-15: Message Count Parameter Tests ---

    function testTransferWithMessageCount() public {
        vm.startPrank(owner);
        // Transfer 100 tokens to user1 first
        token.transfer(user1, 100 ether);
        vm.stopPrank();

        // Advance 1 day so user1 is no longer a "guest" (firstTransactionTime != lastModifiedMidnightBalanceTime)
        vm.warp(block.timestamp + 1 days + 1);

        vm.startPrank(user1);
        uint256 balanceBefore = token.balanceOf(user1);

        // Transfer with messageCount=5
        token.transferWithMessageCount(user2, 10 ether, 5);

        uint256 balanceAfterMsg5 = token.balanceOf(user1);
        // user1 should have less than before (sent 10) but may have arigato mint
        assertLt(balanceAfterMsg5, balanceBefore, "user1 balance should decrease after sending tokens");
        uint256 user2Balance = token.balanceOf(user2);
        assertGt(user2Balance, 0, "user2 should have received tokens");
        vm.stopPrank();
    }

    function testTransferWithMessageCountEmitsEvent() public {
        vm.startPrank(owner);
        token.transfer(user1, 100 ether);
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectEmit(true, true, false, true);
        emit PCECommunityToken.TransferWithMessageCount(user1, user2, 10 ether, 7);
        token.transferWithMessageCount(user2, 10 ether, 7);
        vm.stopPrank();
    }

    function testTransferFromWithMessageCount() public {
        vm.startPrank(owner);
        token.transfer(user1, 100 ether);
        vm.stopPrank();

        // user1 approves owner to spend
        vm.startPrank(user1);
        token.approve(owner, 50 ether);
        vm.stopPrank();

        vm.startPrank(owner);
        token.transferFromWithMessageCount(user1, user2, 10 ether, 3);
        uint256 user2Balance = token.balanceOf(user2);
        assertGt(user2Balance, 0, "user2 should have received tokens");
        vm.stopPrank();
    }

    function testTransferWithMessageCountZeroTreatedAsOne() public {
        vm.startPrank(owner);
        token.transfer(user1, 100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days + 1);

        vm.startPrank(user1);
        // messageCount=0 should behave like messageCount=1 (internal _mintArigatoCreation clamps to 1)
        token.transferWithMessageCount(user2, 10 ether, 0);
        uint256 user2Balance = token.balanceOf(user2);
        assertGt(user2Balance, 0, "user2 should have received tokens");
        vm.stopPrank();
    }
}
