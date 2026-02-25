// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PCECommunityTokenV10} from "../src/PCECommunityTokenV10.sol";
import {PCEToken} from "../src/PCEToken.sol";
import {PCETokenV10} from "../src/PCETokenV10.sol";
import {ExchangeAllowMethod} from "../src/lib/Enum.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Utils} from "../src/lib/Utils.sol";

// Minimal Beacon for testing
contract MinimalBeaconV10 {
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

// Minimal UUPS Proxy for testing
contract MinimalUUPSProxyV10 {
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

    fallback() external payable {
        _delegate(implementation);
    }

    receive() external payable {
        _delegate(implementation);
    }

    function _delegate(address _implementation) internal virtual {
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), _implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

contract PCEV10Test is Test {
    PCETokenV10 public pceToken;
    PCECommunityTokenV10 public token;
    MinimalBeaconV10 public pceCommunityTokenBeacon;
    address public owner;
    address public user1;
    address public user2;

    function setUp() public {
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);

        vm.startPrank(owner);

        PCECommunityTokenV10 communityImpl = new PCECommunityTokenV10();
        PCEToken pceTokenV1 = new PCEToken();
        PCETokenV10 pceTokenV10Impl = new PCETokenV10();

        pceCommunityTokenBeacon = new MinimalBeaconV10(address(communityImpl));

        MinimalUUPSProxyV10 pceTokenProxy = new MinimalUUPSProxyV10(address(pceTokenV1));
        PCEToken(address(pceTokenProxy)).initialize(
            "PCE Token",
            "PCE",
            address(pceCommunityTokenBeacon),
            address(0x687C1D2dd0F422421BeF7aC2a52f50e858CAA867)
        );

        pceTokenProxy.upgradeTo(address(pceTokenV10Impl));
        pceToken = PCETokenV10(address(pceTokenProxy));

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

        address[] memory tokens = pceToken.getTokens();
        token = PCECommunityTokenV10(tokens[0]);
    }

    function testSwapFromLocalToken() public {
        // First swap PCE -> community token (swapToLocalToken)
        vm.startPrank(owner);
        uint256 swapAmount = 100 ether;
        pceToken.swapToLocalToken(address(token), swapAmount);

        uint256 communityBalance = token.balanceOf(owner);
        assertTrue(communityBalance > 0, "Should have community tokens after swap");
        console2.log("Community token balance after swapTo:", communityBalance);

        // Set swapable rates (required for swapFromLocalToken)
        // Need to call as owner of PCEToken
        // swapableToPCERate and swapableToPCEIndividualRate need to be set

        // Advance time by 1 day so midnightBalance gets set
        vm.warp(block.timestamp + 1 days);

        // Trigger midnightBalance update by doing a small transfer
        token.transfer(user1, 1 ether);

        // Advance another day
        vm.warp(block.timestamp + 1 days);

        // Now try swapFromLocalToken - should work without needing approve
        uint256 swapBackAmount = 10 ether;
        uint256 pceBalanceBefore = pceToken.balanceOf(owner);

        pceToken.swapFromLocalToken(address(token), swapBackAmount);

        uint256 pceBalanceAfter = pceToken.balanceOf(owner);
        assertTrue(pceBalanceAfter > pceBalanceBefore, "PCE balance should increase after swap from local");
        console2.log("PCE balance increased by:", pceBalanceAfter - pceBalanceBefore);

        vm.stopPrank();
    }

    function testSwapFromLocalTokenWithoutApprove() public {
        // This test verifies that swapFromLocalToken works WITHOUT user approval
        // (using burnByPCEToken instead of burnFrom)
        vm.startPrank(owner);

        // Swap some PCE to community tokens first
        pceToken.swapToLocalToken(address(token), 100 ether);

        // Advance time for midnightBalance
        vm.warp(block.timestamp + 1 days);
        token.transfer(user1, 1 ether);
        vm.warp(block.timestamp + 1 days);

        // Verify: NO approve call for pceToken on community token
        // swapFromLocalToken should still succeed
        uint256 communityBalanceBefore = token.balanceOf(owner);
        pceToken.swapFromLocalToken(address(token), 5 ether);
        uint256 communityBalanceAfter = token.balanceOf(owner);

        assertTrue(communityBalanceAfter < communityBalanceBefore, "Community tokens should decrease");
        console2.log("Community tokens burned:", communityBalanceBefore - communityBalanceAfter);

        vm.stopPrank();
    }

    function testBurnByPCETokenOnlyCallableByPCEToken() public {
        // burnByPCEToken should only be callable by the PCE token contract
        vm.startPrank(owner);
        token.mint(owner, 100 ether);
        vm.stopPrank();

        // Try calling burnByPCEToken from a non-PCE address (should revert)
        vm.startPrank(user1);
        vm.expectRevert("Only PCE token");
        token.burnByPCEToken(owner, 10 ether);
        vm.stopPrank();
    }

    function testHasDecreaseTimeWithinUsesWednesday() public view {
        // Wednesday is day 6 in the epoch (0=Thursday)
        // Unix epoch starts on Thursday, Jan 1, 1970

        // Pick a Monday and a Tuesday in the same week (no Wednesday between)
        uint256 monday = 1704067200; // 2024-01-01 Monday 00:00 UTC
        uint256 tuesday = monday + 1 days;

        // No Wednesday between Monday and Tuesday
        bool result1 = pceToken.hasDecreaseTimeWithin(monday, tuesday);
        assertFalse(result1, "No decrease between Mon and Tue");

        // Wednesday to Thursday (Wednesday was crossed)
        uint256 wednesday = monday + 2 days; // 2024-01-03 Wednesday
        uint256 thursday = wednesday + 1 days;
        bool result2 = pceToken.hasDecreaseTimeWithin(wednesday, thursday);
        assertTrue(result2, "Decrease should occur crossing Wednesday");
    }

    function testNoMinuteBasedDecrease() public {
        // In V10, waiting just 2 minutes should NOT trigger decrease
        // (unlike V9 where it did)
        uint256 factorBefore = pceToken.getCurrentFactor();

        // Advance 2 minutes
        vm.warp(block.timestamp + 2 minutes);

        uint256 factorAfter = pceToken.getCurrentFactor();
        assertEq(factorBefore, factorAfter, "Factor should NOT change after 2 minutes");
    }

    function testDecreaseOnWednesday() public {
        // Fast forward to just before Wednesday
        // Find next Wednesday from current block.timestamp
        uint256 currentDay = block.timestamp / 1 days;
        uint256 currentWeekday = currentDay % 7; // 0=Thu, 6=Wed
        uint256 daysUntilWednesday = (6 - currentWeekday) % 7;
        if (daysUntilWednesday == 0) daysUntilWednesday = 7;

        // Warp to just before Wednesday
        uint256 beforeWednesday = block.timestamp + (daysUntilWednesday * 1 days) - 1 hours;
        vm.warp(beforeWednesday);

        uint256 factorBeforeWed = pceToken.getCurrentFactor();

        // Warp past Wednesday
        vm.warp(beforeWednesday + 2 hours);

        uint256 factorAfterWed = pceToken.getCurrentFactor();

        // Factor should have decreased
        assertTrue(factorAfterWed < factorBeforeWed, "Factor should decrease after Wednesday");

        // Check it decreased by 0.2% (factor * 998/1000)
        uint256 expected = Math.mulDiv(factorBeforeWed, 998 * 1e18, 1000 * 1e18);
        assertEq(factorAfterWed, expected, "Factor should decrease by 0.2%");
    }

    function testVersion() public view {
        assertEq(pceToken.version(), "1.0.10");
        assertEq(token.version(), "1.0.10");
    }
}
