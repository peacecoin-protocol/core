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

    function testNonzeroFeeWithZeroRawValueIsRejected() public {
        community.setTestRebase(2 ether);
        uint256 reserve = pce.balanceOf(address(pce));
        uint256 balance = community.balanceOf(address(this));
        vm.expectRevert("Fee rounds to zero");
        community.collectTestFee(address(this), RELAYER, 1);
        assertEq(pce.balanceOf(address(pce)), reserve);
        assertEq(pce.balanceOf(RELAYER), 0);
        assertEq(community.balanceOf(address(this)), balance);
    }

    function testFeePayoutUsesRoundedBurnValue() public {
        community.setTestRebase(2 ether);
        uint256 requested = 3;
        uint256 raw = community.displayBalanceToRawBalance(requested);
        uint256 effective = community.rawBalanceToDisplayBalance(raw);
        assertEq(effective, 2);
        uint256 amount = community.collectTestFee(address(this), RELAYER, requested);
        assertEq(amount, effective);
        assertEq(pce.balanceOf(RELAYER), effective);
    }

    function testZeroConfiguredFeeDoesNotBurnOrSwap() public {
        uint256 beforeBalance = community.balanceOf(address(this));
        uint256 beforeReserve = pce.balanceOf(address(pce));
        assertEq(community.collectTestFee(address(this), RELAYER, 0), 0);
        assertEq(community.balanceOf(address(this)), beforeBalance);
        assertEq(pce.balanceOf(address(pce)), beforeReserve);
    }

    function testFuzzFeePayoutDoesNotExceedBurnedDisplayValue(uint256 fee, uint256 split) public {
        fee = bound(fee, 1, 10_000);
        split = bound(split, 2, 1000);
        community.setTestRebase(split * 1 ether);
        uint256 raw = community.displayBalanceToRawBalance(fee);
        uint256 effective = community.rawBalanceToDisplayBalance(raw);
        if (raw == 0 || effective == 0) {
            vm.expectRevert("Fee rounds to zero");
            community.collectTestFee(address(this), RELAYER, fee);
            assertEq(pce.balanceOf(RELAYER), 0);
        } else {
            uint256 beforeSupply = community.totalSupply();
            uint256 amount = community.collectTestFee(address(this), RELAYER, fee);
            assertLe(effective, fee);
            assertEq(amount, effective);
            assertEq(beforeSupply - community.totalSupply(), effective);
        }
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

    function testDustApprovalFeeRevertsWithoutConsumingAuthorization() public {
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
        vm.expectRevert("Fee rounds to zero");
        community.setInfinityApproveFlagWithAuthorization(
            signer, RELAYER, true, 0, type(uint256).max, nonce, v, r, sigS
        );
        assertFalse(community.authorizationState(signer, nonce));
        assertFalse(community.getInfinityApproveFlag(signer, RELAYER));
        assertEq(community.balanceOf(signer), beforeBalance);
        assertEq(pce.balanceOf(RELAYER), 0);
    }

    function testVoucherDustFeeIsWaivedWithoutPCEPayout() public {
        _configureDustFee();
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
        assertEq(community.balanceOf(signer), 10 ether);
        assertEq(pce.balanceOf(RELAYER), 0);
        assertEq(pce.balanceOf(address(pce)), beforeReserve);
    }
}
