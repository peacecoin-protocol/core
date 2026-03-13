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

    function testVersion() public view {
        assertEq(pceToken.version(), "1.0.13");
        assertEq(token.version(), "1.0.13");
    }

    // --- PIP-2: Treasury wallet and capital operations tests ---

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

        // Owner should have TREASURY_MANAGER_ROLE
        assertTrue(
            token.hasRole(token.TREASURY_MANAGER_ROLE(), owner),
            "Owner should have treasury manager role"
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

    function testCapitalIncrease() public {
        address treasury = _setupTreasuryWithDeposit();

        // Initial state: depositedPCEToken=1000e18 (from createToken), exchangeRate=1e18
        uint256 depositedBefore = pceToken.getDepositedPCETokens(address(token));
        uint256 rateBefore = pceToken.getExchangeRate(address(token));
        assertEq(depositedBefore, 1000 ether, "Initial deposited should be 1000e18");
        assertEq(rateBefore, 1 ether, "Initial exchange rate should be 1e18");

        uint256 treasuryBalanceBefore = pceToken.balanceOf(treasury);
        uint256 increaseAmount = 100 ether;

        // Capital increase of 100e18 (treasury has 200 PCE)
        vm.startPrank(owner);
        token.capitalIncrease(increaseAmount);
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

    function testCapitalIncreaseWithSmallDeposit() public {
        // Test with the exact PIP-2 example: deposited=100e18, rate=1e18, increase=50e18
        // We need a community token with depositedPCEToken=100e18

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

        // Capital increase 50e18
        vm.startPrank(owner);
        smallToken.capitalIncrease(50 ether);
        vm.stopPrank();

        // depositedPCEToken = 150e18
        assertEq(pceToken.getDepositedPCETokens(address(smallToken)), 150 ether);

        // exchangeRate = 1e18 * 100e18 / 150e18 = 666666666666666666 (~0.667e18)
        uint256 rateNum = 1 ether * 100 ether;
        uint256 rateDen = 150 ether;
        uint256 expectedRate = rateNum / rateDen;
        assertEq(pceToken.getExchangeRate(address(smallToken)), expectedRate);
    }

    function testCapitalDecrease() public {
        // Test with PIP-2 example: deposited=100e18, rate=1e18, decrease=25e18
        vm.startPrank(owner);

        address[] memory incomeTargetTokens = new address[](0);
        address[] memory outgoTargetTokens = new address[](0);

        pceToken.createToken(
            "Decrease Test Token",
            "DTT",
            100 ether,
            1 ether,
            1, 9800, 1000, 500, 1000, 100,
            ExchangeAllowMethod.All,
            ExchangeAllowMethod.All,
            incomeTargetTokens,
            outgoTargetTokens
        );

        address[] memory tokens_ = pceToken.getTokens();
        PCECommunityToken dToken = PCECommunityToken(tokens_[tokens_.length - 1]);

        address treasury = address(0x9999);
        dToken.initializeTreasury(treasury);
        vm.stopPrank();

        // Verify initial state
        assertEq(pceToken.getDepositedPCETokens(address(dToken)), 100 ether);
        assertEq(pceToken.getExchangeRate(address(dToken)), 1 ether);

        uint256 treasuryBalanceBefore = pceToken.balanceOf(treasury);

        // Capital decrease 25e18
        vm.startPrank(owner);
        dToken.capitalDecrease(25 ether);
        vm.stopPrank();

        // depositedPCEToken = 75e18
        assertEq(pceToken.getDepositedPCETokens(address(dToken)), 75 ether);

        // exchangeRate = 1e18 * 100e18 / 75e18 = 1333333333333333333 (~1.333e18)
        uint256 rateNum = 1 ether * 100 ether;
        uint256 rateDen = 75 ether;
        uint256 expectedRate = rateNum / rateDen;
        assertEq(pceToken.getExchangeRate(address(dToken)), expectedRate);

        // Treasury should receive 25 PCE
        uint256 treasuryBalanceAfter = pceToken.balanceOf(treasury);
        assertEq(
            treasuryBalanceAfter - treasuryBalanceBefore,
            25 ether,
            "Treasury should receive 25 PCE"
        );
    }

    function testCapitalDecreaseFullWithdrawalReverts() public {
        vm.startPrank(owner);

        address[] memory incomeTargetTokens = new address[](0);
        address[] memory outgoTargetTokens = new address[](0);

        pceToken.createToken(
            "Full Withdrawal Test Token",
            "FWT",
            100 ether,
            1 ether,
            1, 9800, 1000, 500, 1000, 100,
            ExchangeAllowMethod.All,
            ExchangeAllowMethod.All,
            incomeTargetTokens,
            outgoTargetTokens
        );

        address[] memory tokens_ = pceToken.getTokens();
        PCECommunityToken fToken = PCECommunityToken(tokens_[tokens_.length - 1]);

        address treasury = address(0xAAAA);
        fToken.initializeTreasury(treasury);

        // Try to withdraw all 100e18 - should revert
        vm.expectRevert("Cannot withdraw full deposit");
        fToken.capitalDecrease(100 ether);

        vm.stopPrank();
    }

    function testUnauthorizedAccess() public {
        _setupTreasury();

        // user1 (not a treasury manager) tries to call capitalIncrease
        vm.startPrank(user1);
        vm.expectRevert("Not treasury manager");
        token.capitalIncrease(10 ether);

        vm.expectRevert("Not treasury manager");
        token.capitalDecrease(10 ether);

        vm.expectRevert("Not treasury manager");
        token.setTreasuryWallet(address(0x5555));

        vm.expectRevert("Not treasury manager");
        token.grantTreasuryManagerRole(user2);

        vm.expectRevert("Not treasury manager");
        token.revokeTreasuryManagerRole(owner);
        vm.stopPrank();

        // user1 tries to call initializeTreasury (not owner)
        vm.startPrank(user1);
        vm.expectRevert();
        token.initializeTreasury(address(0x6666));
        vm.stopPrank();
    }

    function testRoleManagement() public {
        _setupTreasury();

        // Owner has treasury manager role after initializeTreasury
        assertTrue(
            token.hasRole(token.TREASURY_MANAGER_ROLE(), owner),
            "Owner should have treasury manager role"
        );

        // Owner grants role to user1
        vm.startPrank(owner);
        token.grantTreasuryManagerRole(user1);
        vm.stopPrank();

        assertTrue(
            token.hasRole(token.TREASURY_MANAGER_ROLE(), user1),
            "User1 should have treasury manager role"
        );

        // User1 can now revoke owner's role
        vm.startPrank(user1);
        token.revokeTreasuryManagerRole(owner);
        vm.stopPrank();

        assertFalse(
            token.hasRole(token.TREASURY_MANAGER_ROLE(), owner),
            "Owner should no longer have treasury manager role"
        );

        // Owner can no longer call treasury manager functions
        vm.startPrank(owner);
        vm.expectRevert("Not treasury manager");
        token.capitalIncrease(10 ether);
        vm.stopPrank();

        // User1 can still call treasury manager functions (setTreasuryWallet)
        vm.startPrank(user1);
        token.setTreasuryWallet(address(0x7777));
        vm.stopPrank();

        assertEq(token.treasuryWallet(), address(0x7777), "Treasury wallet should be updated");
    }
}
