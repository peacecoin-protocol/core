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
        assertEq(pceToken.version(), "1.0.12");
        assertEq(token.version(), "1.0.13");
    }
}
