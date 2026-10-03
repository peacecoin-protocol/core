// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { PCEToken } from "../src/PCEToken.sol";
import { PCECommunityToken } from "../src/PCECommunityToken.sol";
import { ExchangeAllowMethod } from "../src/lib/Enum.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @dev Test-only access to the shared fee helper; not a production implementation.
contract FeeSafetyHarness is PCECommunityToken {
    function collectTestFee(address payer, address relayer, uint256 fee) external onlyOwner returns (uint256) {
        updateFactorIfNeeded();
        return _collectFeeAsPCE(payer, relayer, fee);
    }

    function setTestFactor(uint256 factor) external onlyOwner {
        lastModifiedFactor = factor;
    }

    function setTestRebase(uint256 factor) external onlyOwner {
        rebaseFactor = factor;
    }
}

contract FeeSafetyTest is Test {
    PCEToken internal pce;
    FeeSafetyHarness internal community;
    address internal constant RELAYER = address(0xC0FFEE);

    function setUp() public {
        pce = PCEToken(deployCode("PCEToken.sol:PCEToken"));
        pce.initialize();
        UpgradeableBeacon beacon = new UpgradeableBeacon(deployCode("FeeSafety.t.sol:FeeSafetyHarness"), address(this));
        pce.setCommunityTokenAddress(address(beacon));
        vm.store(address(pce), bytes32(uint256(6)), bytes32(uint256(300)));
        vm.store(address(pce), bytes32(uint256(7)), bytes32(uint256(300)));
        pce.mint(address(this), 10_000 ether);
        pce.createToken(
            "Fee Safety",
            "FEE",
            1000 ether,
            1 ether,
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
        community = FeeSafetyHarness(pce.getTokens()[0]);
        vm.warp(block.timestamp + 1 days);
        community.transfer(address(0xBEEF), 1 ether);
        vm.warp(block.timestamp + 1 days);
        community.updateFactorIfNeeded();
    }

    function testPositiveDustFeeIsCeiledAndPaidInFull() public {
        community.setTestRebase(2 ether);
        assertEq(community.displayBalanceToRawBalance(1), 0);
        assertEq(community.displayFeeToRawBalance(1), 1 ether);
        uint256 balance = community.balanceOf(address(this));
        assertEq(community.collectTestFee(address(this), RELAYER, 1), 1);
        assertEq(pce.balanceOf(RELAYER), 1);
        assertEq(balance - community.balanceOf(address(this)), 2);
    }

    function testFeePayoutUsesConfiguredValueNotCeilingSurplus() public {
        community.setTestRebase(2 ether);
        assertEq(community.displayFeeToRawBalance(3), 2 ether);
        uint256 balance = community.balanceOf(address(this));
        assertEq(community.collectTestFee(address(this), RELAYER, 3), 3);
        assertEq(pce.balanceOf(RELAYER), 3);
        assertEq(balance - community.balanceOf(address(this)), 4);
    }

    function testZeroConfiguredFeeDoesNotBurnOrSwap() public {
        uint256 beforeBalance = community.balanceOf(address(this));
        uint256 beforeReserve = pce.balanceOf(address(pce));
        assertEq(community.collectTestFee(address(this), RELAYER, 0), 0);
        assertEq(community.balanceOf(address(this)), beforeBalance);
        assertEq(pce.balanceOf(address(pce)), beforeReserve);
    }

    function testFuzzFeePayoutCoveredByCeilingBurn(uint256 fee, uint256 rebase) public {
        fee = bound(fee, 1, 10_000);
        rebase = bound(rebase, 1e15, 1000 ether);
        community.setTestRebase(rebase);
        uint256 raw = community.displayFeeToRawBalance(fee);
        uint256 effective = community.rawBalanceToDisplayBalance(raw);
        assertGe(effective, fee);
        assertGt(raw, 0);
        if (raw > 1) assertLt(community.rawBalanceToDisplayBalance(raw - 1), fee);
        uint256 amount = community.collectTestFee(address(this), RELAYER, fee);
        assertEq(amount, fee);
        assertEq(pce.balanceOf(RELAYER), fee);
    }

    function testFuzzBothCeilingStagesCoverFee(uint256 fee, uint256 rebase, uint256 factor) public {
        fee = bound(fee, 1, 10_000);
        rebase = bound(rebase, 1e15, 1000 ether);
        factor = bound(factor, 1e15, 1 ether);
        community.setTestRebase(rebase);
        community.setTestFactor(factor);
        uint256 raw = community.displayFeeToRawBalance(fee);
        assertGe(community.rawBalanceToDisplayBalance(raw), fee);
        assertLt(community.rawBalanceToDisplayBalance(raw - 1), fee);
    }

    function testDustTransferFromAllowanceCoversCeilingFee() public {
        _configureDustFee();
        uint256 pk = 0xFEE3;
        address spender = vm.addr(pk);
        address recipient = address(0xCAFE);
        bytes32 nonce = keccak256("dust-allowance");
        (uint8 v, bytes32 r, bytes32 sigS) = _signAuthorization(
            pk,
            abi.encode(
                community.TRANSFER_FROM_WITH_AUTHORIZATION_TYPEHASH(),
                spender,
                address(this),
                recipient,
                uint256(2),
                uint256(0),
                type(uint256).max,
                nonce
            )
        );
        community.approve(spender, 2);
        uint256 beforeBalance = community.balanceOf(address(this));
        vm.expectRevert("Insufficient allowance");
        vm.prank(RELAYER);
        community.transferFromWithAuthorization(
            spender, address(this), recipient, 2, 0, type(uint256).max, nonce, v, r, sigS
        );
        assertFalse(community.authorizationState(spender, nonce));
        assertEq(community.balanceOf(address(this)), beforeBalance);
        assertEq(community.allowance(address(this), spender), 2);
        community.approve(spender, 4);
        vm.prank(RELAYER);
        community.transferFromWithAuthorization(
            spender, address(this), recipient, 2, 0, type(uint256).max, nonce, v, r, sigS
        );
        assertTrue(community.authorizationState(spender, nonce));
        assertEq(community.allowance(address(this), spender), 0);
        assertEq(beforeBalance - community.balanceOf(address(this)), 4);
        assertEq(community.balanceOf(recipient), 2);
        assertEq(pce.balanceOf(RELAYER), 1);
    }

    function testRevertedFeeSwapRollsBackApprovalBurnAndNonce() public {
        uint256 pk = 0xFEE4;
        address signer = vm.addr(pk);
        community.transfer(signer, 10 ether);
        _configureDustFee();
        bytes32 nonce = keccak256("rollback-approval");
        (uint8 v, bytes32 r, bytes32 sigS) = _signAuthorization(
            pk,
            abi.encode(
                community.SET_INFINITY_APPROVE_FLAG_WITH_AUTHORIZATION_TYPEHASH(),
                signer,
                RELAYER,
                true,
                uint256(0),
                type(uint256).max,
                nonce
            )
        );
        vm.mockCallRevert(
            address(pce),
            abi.encodeWithSelector(PCEToken.swapFeeFromLocalToken.selector, address(community), RELAYER, uint256(1)),
            abi.encodeWithSignature("Error(string)", "Insufficient deposited PCE token reserve")
        );
        uint256 beforeBalance = community.balanceOf(signer);
        uint256 beforeSupply = community.totalSupply();
        uint256 beforeReserve = pce.balanceOf(address(pce));
        vm.expectRevert("Insufficient deposited PCE token reserve");
        vm.prank(RELAYER);
        community.setInfinityApproveFlagWithAuthorization(
            signer, RELAYER, true, 0, type(uint256).max, nonce, v, r, sigS
        );
        assertFalse(community.authorizationState(signer, nonce));
        assertFalse(community.getInfinityApproveFlag(signer, RELAYER));
        assertEq(community.balanceOf(signer), beforeBalance);
        assertEq(community.totalSupply(), beforeSupply);
        assertEq(pce.balanceOf(address(pce)), beforeReserve);
        assertEq(pce.balanceOf(RELAYER), 0);
    }

    function _configureDustFee() internal {
        pce.setNativeTokenToPceTokenRate(uint160(1 << 96));
        pce.setMetaTransactionGas(1);
        pce.setMetaTransactionPriorityFee(1);
        vm.fee(0);
        community.setTestRebase(2 ether);
        assertEq(community.getMetaTransactionFee(), 1);
        assertEq(community.displayBalanceToRawBalance(1), 0);
    }

    function _signAuthorization(uint256 pk, bytes memory data) internal view returns (uint8, bytes32, bytes32) {
        return vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", community.DOMAIN_SEPARATOR(), keccak256(data))));
    }

    function testDustApprovalFeeIsCollectedAndAuthorizationConsumed() public {
        uint256 pk = 0xFEE1;
        address signer = vm.addr(pk);
        community.transfer(signer, 10 ether);
        _configureDustFee();
        bytes32 nonce = keccak256("dust-approval");
        (uint8 v, bytes32 r, bytes32 sigS) = _signAuthorization(
            pk,
            abi.encode(
                community.SET_INFINITY_APPROVE_FLAG_WITH_AUTHORIZATION_TYPEHASH(),
                signer,
                RELAYER,
                true,
                uint256(0),
                type(uint256).max,
                nonce
            )
        );
        uint256 beforeBalance = community.balanceOf(signer);
        vm.prank(RELAYER);
        community.setInfinityApproveFlagWithAuthorization(
            signer, RELAYER, true, 0, type(uint256).max, nonce, v, r, sigS
        );
        assertTrue(community.authorizationState(signer, nonce));
        assertTrue(community.getInfinityApproveFlag(signer, RELAYER));
        assertEq(beforeBalance - community.balanceOf(signer), 2);
        assertEq(pce.balanceOf(RELAYER), 1);
    }

    function testVoucherDustFeeIsWithheldAndPaidInFull() public {
        _claimVoucherFee(false);
    }

    function testVoucherZeroConfiguredFeeRemainsFree() public {
        _claimVoucherFee(true);
    }

    function _claimVoucherFee(bool zeroFee) internal {
        _configureDustFee();
        if (zeroFee) pce.setMetaTransactionGas(0);
        uint256 pk = 0xFEE2;
        address signer = vm.addr(pk);
        string memory code = "DUST-VOUCHER";
        bytes32 leaf = keccak256(abi.encodePacked(code));
        community.registerVoucherIssuance(
            "DUST001", "dust", 10 ether, 1, 10 ether, 10 ether, 0, block.timestamp + 365 days, leaf, ""
        );
        bytes32 nonce = keccak256("dust-voucher");
        (uint8 v, bytes32 r, bytes32 sigS) = _signAuthorization(
            pk,
            abi.encode(
                community.CLAIM_WITH_AUTHORIZATION_TYPEHASH(),
                signer,
                keccak256(bytes("DUST001")),
                keccak256(bytes(code)),
                uint256(0),
                type(uint256).max,
                nonce
            )
        );
        uint256 beforeReserve = pce.balanceOf(address(pce));
        vm.prank(RELAYER);
        community.claimVoucherWithAuthorization(
            signer, "DUST001", code, new bytes32[](0), 0, type(uint256).max, nonce, v, r, sigS
        );
        assertEq(community.balanceOf(signer), zeroFee ? 10 ether : 10 ether - 2);
        assertEq(pce.balanceOf(RELAYER), zeroFee ? 0 : 1);
        assertEq(pce.balanceOf(address(pce)), zeroFee ? beforeReserve : beforeReserve - 1);
    }
}
