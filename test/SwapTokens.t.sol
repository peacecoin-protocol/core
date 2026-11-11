// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { PCEToken } from "../src/PCEToken.sol";
import { PCECommunityToken } from "../src/PCECommunityToken.sol";
import { ExchangeAllowMethod } from "../src/lib/Enum.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract SwapTokensTest is Test {
    PCEToken internal pce;
    PCECommunityToken internal tokenA;
    PCECommunityToken internal tokenB;
    address internal constant USER = address(0xA11CE);

    function setUp() public {
        pce = PCEToken(deployCode("PCEToken.sol:PCEToken"));
        pce.initialize();
        UpgradeableBeacon beacon =
            new UpgradeableBeacon(deployCode("PCECommunityToken.sol:PCECommunityToken"), address(this));
        pce.setCommunityTokenAddress(address(beacon));
        // swapableToPCERate / swapableToPCEIndividualRate = 30%
        vm.store(address(pce), bytes32(uint256(6)), bytes32(uint256(3000)));
        vm.store(address(pce), bytes32(uint256(7)), bytes32(uint256(3000)));
        pce.mint(address(this), 10_000 ether);

        tokenA = _createToken("Token A", "TKA", 1 ether, ExchangeAllowMethod.All, ExchangeAllowMethod.All);
        tokenB = _createToken("Token B", "TKB", 2 ether, ExchangeAllowMethod.All, ExchangeAllowMethod.All);

        tokenA.transfer(USER, 100 ether);
        // Let the midnight balances that drive the daily limits settle.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        tokenA.transfer(address(0xBEEF), 1 ether);
        vm.prank(USER);
        tokenA.transfer(address(0xBEEF), 1 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        // Refresh today's supply and balance snapshots so the limits read by the tests do not
        // change on the first swap of the day.
        tokenA.transfer(address(this), 0);
        vm.prank(USER);
        tokenA.transfer(USER, 0);
    }

    function _createToken(
        string memory name,
        string memory symbol,
        uint256 dilution,
        ExchangeAllowMethod income,
        ExchangeAllowMethod outgo
    )
        internal
        returns (PCECommunityToken)
    {
        pce.createToken(
            name,
            symbol,
            1000 ether,
            dilution,
            1,
            10_000,
            1000,
            500,
            1000,
            100,
            income,
            outgo,
            new address[](0),
            new address[](0)
        );
        address[] memory tokens = pce.getTokens();
        return PCECommunityToken(tokens[tokens.length - 1]);
    }

    function testSwapTokensMovesBalancesAndReserves() public {
        uint256 amount = 10 ether;
        uint256 depositedA = pce.getDepositedPCETokens(address(tokenA));
        uint256 depositedB = pce.getDepositedPCETokens(address(tokenB));
        uint256 balanceA = tokenA.balanceOf(USER);
        uint256 pceSupply = pce.totalSupply();
        uint256 pceReserve = pce.balanceOf(address(pce));

        vm.prank(USER);
        tokenA.swapTokens(address(tokenB), amount);

        // 1 A = 1 PCE, 1 PCE = 2 B, no decay configured.
        assertEq(balanceA - tokenA.balanceOf(USER), amount);
        assertEq(tokenB.balanceOf(USER), 20 ether);
        assertEq(pce.getDepositedPCETokens(address(tokenA)), depositedA - 10 ether);
        assertEq(pce.getDepositedPCETokens(address(tokenB)), depositedB + 10 ether);
        assertEq(pce.totalSupply(), pceSupply);
        assertEq(pce.balanceOf(address(pce)), pceReserve);
    }

    function testSwapTokensDoesNotConsumeSourceDailyLimit() public {
        uint256 amount = 10 ether;
        uint256 globalBefore = tokenA.getRemainingSwapableToPCEBalance();
        uint256 individualBefore = tokenA.getRemainingSwapableToPCEBalanceForIndividual(USER);

        vm.prank(USER);
        tokenA.swapTokens(address(tokenB), amount);

        assertEq(tokenA.getRemainingSwapableToPCEBalance(), globalBefore);
        assertEq(tokenA.getRemainingSwapableToPCEBalanceForIndividual(USER), individualBefore);
    }

    function testSwapTokensAboveIndividualDailyLimit() public {
        uint256 amount = tokenA.getRemainingSwapableToPCEBalanceForIndividual(USER) + 1;
        assertLe(amount, tokenA.balanceOf(USER));

        vm.prank(USER);
        tokenA.swapTokens(address(tokenB), amount);
        assertEq(tokenB.balanceOf(USER), amount * 2);
    }

    function testSwapTokensAboveGlobalDailyLimit() public {
        uint256 amount = tokenA.getRemainingSwapableToPCEBalance() + 1;
        assertLe(amount, tokenA.balanceOf(address(this)));

        uint256 balanceB = tokenB.balanceOf(address(this));
        tokenA.swapTokens(address(tokenB), amount);
        assertEq(tokenB.balanceOf(address(this)) - balanceB, amount * 2);
    }

    function testSwapTokensRespectsOutgoAllowList() public {
        PCECommunityToken closed =
            _createToken("Closed", "CLS", 1 ether, ExchangeAllowMethod.All, ExchangeAllowMethod.None);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        closed.transfer(address(0xBEEF), 1 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert("Outgo exchange not allowed");
        closed.swapTokens(address(tokenB), 1 ether);
    }

    function testSwapTokensRespectsIncomeAllowList() public {
        PCECommunityToken closed =
            _createToken("Closed", "CLS", 1 ether, ExchangeAllowMethod.None, ExchangeAllowMethod.All);
        vm.prank(USER);
        vm.expectRevert("Income exchange not allowed");
        tokenA.swapTokens(address(closed), 1 ether);
    }

    function testSwapTokensRejectsSameToken() public {
        vm.prank(USER);
        vm.expectRevert("Cannot swap to same token");
        tokenA.swapTokens(address(tokenA), 1 ether);
    }

    function testSwapTokensRejectsUnregisteredTarget() public {
        // A community token wired to the real PCEToken that accepts incoming exchanges, but was
        // never registered by `createToken`.
        PCECommunityToken stray = PCECommunityToken(deployCode("PCECommunityToken.sol:PCECommunityToken"));
        vm.startPrank(address(pce));
        stray.initialize("Stray", "STR", 1 ether);
        stray.setTokenSettings(
            1,
            10_000,
            1000,
            500,
            1000,
            100,
            ExchangeAllowMethod.All,
            ExchangeAllowMethod.All,
            new address[](0),
            new address[](0)
        );
        vm.stopPrank();

        vm.prank(USER);
        vm.expectRevert("Target token not found");
        tokenA.swapTokens(address(stray), 1 ether);
    }

    function testSwapBetweenLocalTokensOnlyCallableByCommunityToken() public {
        vm.prank(USER);
        vm.expectRevert("Caller must be a community token");
        pce.swapBetweenLocalTokens(address(tokenB), USER, 1 ether);
    }

    function testSwapTokensDoesNotMintWithoutBurn() public {
        uint256 balanceA = tokenA.balanceOf(USER);
        vm.prank(USER);
        vm.expectRevert("Insufficient balance");
        tokenA.swapTokens(address(tokenB), balanceA + 1);
        assertEq(tokenB.balanceOf(USER), 0);
    }

    function testSwapToPCECountsTowardDailyOutflow() public {
        uint256 remaining = pce.getRemainingDailyPCEOutflow(address(tokenA));
        // 30% of the 1000 PCE reserve at the start of the day.
        assertEq(remaining, 300 ether);

        vm.prank(USER);
        pce.swapFromLocalToken(address(tokenA), 10 ether);

        assertEq(pce.getRemainingDailyPCEOutflow(address(tokenA)), remaining - 10 ether);
    }

    function _drainReserveWithoutBurn(uint256 pceAmount) internal {
        // Relayer fees take PCE out of A's reserve without burning A, leaving A under-collateralized.
        vm.prank(address(tokenA));
        pce.swapFeeFromLocalToken(address(tokenA), address(0xFEE), pceAmount);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        tokenA.transfer(address(this), 0);
    }

    function testSwapToPCECappedByMidnightReserve() public {
        _drainReserveWithoutBurn(900 ether);

        // The supply-based limit would be 30% of about 1000 A, but only 30 PCE may leave today.
        (uint256 limitInToken, uint256 remainingInToken) = pce.getDailyPCEOutflowInToken(address(tokenA));
        assertEq(limitInToken, 30 ether);
        assertEq(remainingInToken, 30 ether);
        assertEq(tokenA.getTodaySwapableToPCEBalance(), 30 ether);
        assertEq(tokenA.getRemainingSwapableToPCEBalance(), 30 ether);

        pce.swapFromLocalToken(address(tokenA), 30 ether);
        assertEq(tokenA.getRemainingSwapableToPCEBalance(), 0);
        vm.expectRevert("Exceeds daily swap limit");
        pce.swapFromLocalToken(address(tokenA), 1);
    }

    function testPCEOutflowCheckedInPCEUnits() public {
        _drainReserveWithoutBurn(900 ether);
        // Even if the community token reports a larger remaining balance, PCEToken enforces the cap.
        vm.mockCall(
            address(tokenA),
            abi.encodeWithSelector(PCECommunityToken.getRemainingSwapableToPCEBalance.selector),
            abi.encode(type(uint256).max)
        );
        vm.expectRevert("Exceeds daily PCE outflow limit");
        pce.swapFromLocalToken(address(tokenA), 31 ether);
    }

    function testOutflowDayBoundary() public {
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days - 1);
        uint256 remaining = pce.getRemainingDailyPCEOutflow(address(tokenA));
        pce.swapToLocalToken(address(tokenA), 100 ether);
        assertEq(pce.getRemainingDailyPCEOutflow(address(tokenA)), remaining);

        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(
            pce.getRemainingDailyPCEOutflow(address(tokenA)), pce.getDepositedPCETokens(address(tokenA)) * 3000 / 10_000
        );
    }

    function testSelfMadeCommunityCannotSpeedUpOutflow() public {
        // A holder creates their own community C and moves 500 A of reserve into it.
        PCECommunityToken own = _createToken("Own", "OWN", 1 ether, ExchangeAllowMethod.All, ExchangeAllowMethod.All);
        tokenA.swapTokens(address(own), 500 ether);
        assertEq(pce.getRemainingDailyPCEOutflow(address(own)), 0);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        own.transfer(address(this), 0);
        uint256 midnightDeposited = pce.getDepositedPCETokens(address(own));

        // Splitting C several times does not raise what may leave C's reserve today.
        pce.splitToken(address(own), own.totalSupply());
        pce.splitToken(address(own), own.totalSupply());
        own.transfer(address(this), 0);

        uint256 pceBefore = pce.balanceOf(address(this));
        pce.swapFromLocalToken(address(own), own.getRemainingSwapableToPCEBalance());
        assertLe(pce.balanceOf(address(this)) - pceBefore, midnightDeposited * 3000 / 10_000);
        vm.expectRevert();
        pce.swapFromLocalToken(address(own), 1 ether);
    }

    function testDirectSwapDoesNotRaiseTodayOutflow() public {
        uint256 remainingA = pce.getRemainingDailyPCEOutflow(address(tokenA));
        uint256 remainingB = pce.getRemainingDailyPCEOutflow(address(tokenB));
        uint256 depositedB = pce.getDepositedPCETokens(address(tokenB));

        vm.prank(USER);
        tokenA.swapTokens(address(tokenB), 50 ether);

        // Both caps use the reserves at the start of the day.
        assertEq(pce.getRemainingDailyPCEOutflow(address(tokenA)), remainingA);
        assertEq(pce.getRemainingDailyPCEOutflow(address(tokenB)), remainingB);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(pce.getRemainingDailyPCEOutflow(address(tokenB)), (depositedB + 50 ether) * 3000 / 10_000);
    }

    function testSplitDoesNotReopenDailyOutflow() public {
        pce.swapFromLocalToken(address(tokenA), tokenA.getRemainingSwapableToPCEBalanceForIndividual(address(this)));
        uint256 remaining = pce.getRemainingDailyPCEOutflow(address(tokenA));

        // Doubling the display supply raises the supply-based limit but not the reserve cap.
        pce.splitToken(address(tokenA), tokenA.totalSupply());
        tokenA.transfer(address(this), 0);

        assertEq(pce.getRemainingDailyPCEOutflow(address(tokenA)), remaining);
        (, uint256 remainingInToken) = pce.getDailyPCEOutflowInToken(address(tokenA));
        assertLe(tokenA.getRemainingSwapableToPCEBalance(), remainingInToken);
    }

    function testSameDayInflowDoesNotRaiseOutflow() public {
        uint256 remaining = pce.getRemainingDailyPCEOutflow(address(tokenA));

        pce.swapToLocalToken(address(tokenA), 100 ether);
        pce.increaseTokenValue(address(tokenA), 100 ether);
        assertEq(pce.getRemainingDailyPCEOutflow(address(tokenA)), remaining);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(
            pce.getRemainingDailyPCEOutflow(address(tokenA)), pce.getDepositedPCETokens(address(tokenA)) * 3000 / 10_000
        );
    }

    function testNewTokenHasNoOutflowOnCreationDay() public {
        PCECommunityToken fresh =
            _createToken("Fresh", "FRS", 1 ether, ExchangeAllowMethod.All, ExchangeAllowMethod.All);
        assertEq(pce.getRemainingDailyPCEOutflow(address(fresh)), 0);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(pce.getRemainingDailyPCEOutflow(address(fresh)), 300 ether);
    }

    function testFeeAfterCapIsNotBlockedOrCounted() public {
        _drainReserveWithoutBurn(900 ether);
        pce.swapFromLocalToken(address(tokenA), 30 ether);
        assertEq(pce.getRemainingDailyPCEOutflow(address(tokenA)), 0);

        vm.prank(address(tokenA));
        pce.swapFeeFromLocalToken(address(tokenA), address(0xFEE), 1 ether);

        (, uint256 used) = pce.getDailyPCEOutflow(address(tokenA));
        assertEq(used, 30 ether);
    }
}
