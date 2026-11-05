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

    function testSwapTokensCountsTowardSourceDailyLimit() public {
        uint256 amount = 10 ether;
        uint256 globalBefore = tokenA.getRemainingSwapableToPCEBalance();
        uint256 individualBefore = tokenA.getRemainingSwapableToPCEBalanceForIndividual(USER);

        vm.prank(USER);
        tokenA.swapTokens(address(tokenB), amount);

        assertEq(tokenA.getRemainingSwapableToPCEBalance(), globalBefore - amount);
        assertEq(tokenA.getRemainingSwapableToPCEBalanceForIndividual(USER), individualBefore - amount);
    }

    function testSwapTokensRevertsOverIndividualDailyLimit() public {
        uint256 remaining = tokenA.getRemainingSwapableToPCEBalanceForIndividual(USER);
        assertGt(remaining, 0);
        vm.prank(USER);
        vm.expectRevert("Exceeds daily individual swap limit");
        tokenA.swapTokens(address(tokenB), remaining + 1);

        vm.prank(USER);
        tokenA.swapTokens(address(tokenB), remaining);
    }

    function testSwapTokensRevertsOverGlobalDailyLimit() public {
        uint256 remaining = tokenA.getRemainingSwapableToPCEBalance();
        vm.expectRevert("Exceeds daily swap limit");
        tokenA.swapTokens(address(tokenB), remaining + 1);
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
}
