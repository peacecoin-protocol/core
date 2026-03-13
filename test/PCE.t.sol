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

    // --- PIP-3: Meta-Transaction Fee Auto-Swap Tests ---

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
}
