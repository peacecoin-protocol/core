// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { WrappedPCEToken } from "../src/WrappedPCEToken.sol";
import { PeaceCoinTokenDev } from "../src/PeaceCoinTokenDev.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

contract WrappedPCETokenTest is Test {
    WrappedPCEToken public implementation;
    WrappedPCEToken public wpce;
    PeaceCoinTokenDev public pceToken;

    address public owner = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);


    function setUp() public {
        // Deploy PCE token
        pceToken = new PeaceCoinTokenDev("PeaceCoin Token", "PCE");

        // Deploy implementation
        implementation = new WrappedPCEToken();

        // Deploy WPCE proxy and initialize
        bytes memory initDataWPCE = abi.encodeWithSelector(
            WrappedPCEToken.initialize.selector,
            "Wrapped PeaceCoin Token",
            "WPCE",
            address(pceToken),
            owner
        );
        ERC1967Proxy proxyWPCE = new ERC1967Proxy(address(implementation), initDataWPCE);
        wpce = WrappedPCEToken(address(proxyWPCE));

        // Mint some tokens for testing
        pceToken.mint(alice, 1000 ether);
        pceToken.mint(bob, 1000 ether);
    }

    function testInitialization() public view {
        assertEq(wpce.name(), "Wrapped PeaceCoin Token");
        assertEq(wpce.symbol(), "WPCE");
        assertEq(address(wpce.pceToken()), address(pceToken));
        assertEq(wpce.owner(), owner);
    }

    function testDepositFor() public {
        uint256 wrapAmount = 100 ether;

        // Test WPCE deposit
        vm.startPrank(alice);
        pceToken.approve(address(wpce), wrapAmount);

        uint256 pceBalanceBefore = pceToken.balanceOf(alice);
        uint256 wpceBalanceBefore = wpce.balanceOf(alice);

        bool success = wpce.depositFor(alice, wrapAmount);
        assertTrue(success);

        assertEq(pceToken.balanceOf(alice), pceBalanceBefore - wrapAmount);
        assertEq(wpce.balanceOf(alice), wpceBalanceBefore + wrapAmount);
        assertEq(pceToken.balanceOf(address(wpce)), wrapAmount);
        vm.stopPrank();
    }

    function testWithdrawTo() public {
        uint256 wrapAmount = 100 ether;
        uint256 unwrapAmount = 50 ether;

        // First wrap some tokens
        vm.startPrank(alice);
        pceToken.approve(address(wpce), wrapAmount);
        wpce.depositFor(alice, wrapAmount);

        // Test withdraw
        uint256 pceBalanceBefore = pceToken.balanceOf(alice);
        uint256 wpceBalanceBefore = wpce.balanceOf(alice);

        bool success = wpce.withdrawTo(alice, unwrapAmount);
        assertTrue(success);

        assertEq(pceToken.balanceOf(alice), pceBalanceBefore + unwrapAmount);
        assertEq(wpce.balanceOf(alice), wpceBalanceBefore - unwrapAmount);
        assertEq(pceToken.balanceOf(address(wpce)), wrapAmount - unwrapAmount);
        vm.stopPrank();
    }

    function testWithdrawInsufficientBalance() public {
        vm.startPrank(alice);
        vm.expectRevert();
        wpce.withdrawTo(alice, 100 ether);
        vm.stopPrank();
    }


    function testVotingPower() public {
        uint256 wrapAmount = 100 ether;

        // Wrap tokens
        vm.startPrank(alice);
        pceToken.approve(address(wpce), wrapAmount);
        wpce.depositFor(alice, wrapAmount);

        // Delegate to self
        wpce.delegate(alice);
        vm.stopPrank();

        // Move to next block to update voting power
        vm.roll(block.number + 1);

        // Check voting power
        assertEq(wpce.getVotes(alice), wrapAmount);
    }

    function testDelegation() public {
        uint256 wrapAmount = 100 ether;

        // Wrap tokens
        vm.startPrank(alice);
        pceToken.approve(address(wpce), wrapAmount);
        wpce.depositFor(alice, wrapAmount);

        // Delegate to bob
        wpce.delegate(bob);
        vm.stopPrank();

        // Move to next block
        vm.roll(block.number + 1);

        // Check voting power
        assertEq(wpce.getVotes(alice), 0);
        assertEq(wpce.getVotes(bob), wrapAmount);
    }

    function testClockMode() public view {
        assertEq(wpce.clock(), uint48(block.number));
        assertEq(wpce.CLOCK_MODE(), "mode=blocknumber&from=default");
    }

    function testUnderlyingToken() public view {
        assertEq(address(wpce.pceToken()), address(pceToken));
        assertEq(address(wpce.underlying()), address(pceToken));
    }

    function testUpgradeAuthorization() public {
        // Only owner can upgrade
        vm.prank(alice);
        vm.expectRevert();
        wpce.upgradeToAndCall(address(0x123), "");

        // Owner can upgrade (would revert with "ERC1967: new implementation is not UUPS")
        vm.expectRevert();
        wpce.upgradeToAndCall(address(0x123), "");
    }
    
    function testApproveAndWrap() public {
        uint256 wrapAmount = 100 ether;
        
        // This simulates an EIP-7702 delegated call where alice's EOA
        // temporarily has the WPCE contract code
        vm.startPrank(alice);
        
        // First give alice the ability to call as if she has contract code
        // In real EIP-7702, this would be handled by the AUTH opcode
        
        // The approveAndWrap should work when alice calls it on herself
        // But since we can't fully simulate EIP-7702 in tests, we test the logic
        
        // Direct test: alice calls WPCE's approveAndWrap
        // This would fail in normal circumstances but work with EIP-7702
        vm.expectRevert(); // Will revert because alice can't approve on behalf of WPCE
        wpce.approveAndWrap(wrapAmount);
        
        vm.stopPrank();
    }
    
    function testCallerHasCode() public {
        // Contract calling should return true
        assertTrue(wpce.callerHasCode());
        
        // EOA calling should return false (in non-EIP-7702 context)
        vm.prank(alice);
        assertFalse(wpce.callerHasCode());
    }

}
