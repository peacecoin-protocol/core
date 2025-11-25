// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test, console2 } from "forge-std/Test.sol";
import { PCECommunityTokenV9 } from "../src/PCECommunityTokenV9.sol";
import { PCETokenV9 } from "../src/PCETokenV9.sol";
import { ExchangeAllowMethod } from "../src/lib/Enum.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract VoucherSystemSimpleTest is Test {
    PCETokenV9 public pceToken;
    PCECommunityTokenV9 public token;
    UpgradeableBeacon public beacon;

    address public owner;
    address public issuer;
    address public claimer1;

    uint256 public initialSupply = 10000 ether;

    // Simple 3-leaf merkle tree for testing
    // leaves: [leaf0, leaf1, leaf2]
    // tree:
    //       root
    //      /    \
    //   hash01  leaf2
    //   /    \
    // leaf0  leaf1
    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function setUp() public {
        owner = address(this);
        issuer = address(0x1);
        claimer1 = address(0x2);

        // Deploy implementation
        PCECommunityTokenV9 impl = new PCECommunityTokenV9();

        // Deploy beacon
        beacon = new UpgradeableBeacon(address(impl), owner);

        // Deploy PCEToken
        pceToken = new PCETokenV9();

        vm.startPrank(owner);

        pceToken.initialize();
        pceToken.mint(owner, initialSupply);
        pceToken.setCommunityTokenAddress(address(beacon));
        pceToken.setNativeTokenToPceTokenRate(uint160(1 << 96));
        pceToken.setMetaTransactionGas(21000);
        pceToken.setMetaTransactionPriorityFee(1 gwei);

        vm.stopPrank();
    }

    function testSimpleVoucherFlow() public {
        // Create community token
        vm.startPrank(owner);

        address[] memory emptyArray = new address[](0);
        pceToken.createToken(
            "Community Token",
            "CT",
            100 ether,
            10 ** 18,
            0,
            10_000,
            100,
            100,
            5000,
            100,
            ExchangeAllowMethod.All,
            ExchangeAllowMethod.All,
            emptyArray,
            emptyArray
        );

        address[] memory tokens = pceToken.getTokens();
        token = PCECommunityTokenV9(tokens[0]);

        // Transfer tokens to issuer
        token.transfer(issuer, 100 ether);
        vm.stopPrank();

        // Create simple merkle tree with 3 codes
        bytes32 leaf0 = keccak256(abi.encodePacked("CODE001"));
        bytes32 leaf1 = keccak256(abi.encodePacked("CODE002"));
        bytes32 leaf2 = keccak256(abi.encodePacked("CODE003"));

        bytes32 hash01 = hashPair(leaf0, leaf1);
        bytes32 root = hashPair(hash01, leaf2);

        // Register voucher issuance
        vm.startPrank(issuer);
        token.registerVoucherIssuance(
            "VOUCHER001",           // issuanceId
            "Test Voucher",         // name
            10 ether,               // amountPerClaim
            1,                      // countLimitPerUser
            30 ether,               // totalAmountLimit
            30 ether,               // initialFunds
            block.timestamp - 1,    // startTime
            block.timestamp + 1 days, // endTime
            root,                   // merkleRoot
            ""                      // ipfsCid (empty for test)
        );
        vm.stopPrank();

        // Verify issuance
        assertEq(token.balanceOf(issuer), 70 ether, "Issuer should have 70 tokens left");

        // Claim with CODE001 (proof: [leaf1, leaf2])
        bytes32[] memory proof0 = new bytes32[](2);
        proof0[0] = leaf1;
        proof0[1] = leaf2;

        vm.startPrank(claimer1);
        token.claimVoucher("VOUCHER001", "CODE001", proof0);
        vm.stopPrank();

        assertEq(token.balanceOf(claimer1), 10 ether, "Claimer should receive 10 tokens");
    }

    function testCannotClaimTwice() public {
        // Setup
        vm.startPrank(owner);
        address[] memory emptyArray = new address[](0);
        pceToken.createToken(
            "Community Token",
            "CT",
            100 ether,
            10 ** 18,
            0,
            10_000,
            100,
            100,
            5000,
            100,
            ExchangeAllowMethod.All,
            ExchangeAllowMethod.All,
            emptyArray,
            emptyArray
        );

        address[] memory tokens = pceToken.getTokens();
        token = PCECommunityTokenV9(tokens[0]);
        token.transfer(issuer, 100 ether);
        vm.stopPrank();

        bytes32 leaf0 = keccak256(abi.encodePacked("CODE001"));
        bytes32 leaf1 = keccak256(abi.encodePacked("CODE002"));
        bytes32 leaf2 = keccak256(abi.encodePacked("CODE003"));

        bytes32 hash01 = hashPair(leaf0, leaf1);
        bytes32 root = hashPair(hash01, leaf2);

        vm.startPrank(issuer);
        token.registerVoucherIssuance(
            "VOUCHER001",           // issuanceId
            "Test Voucher",         // name
            10 ether,               // amountPerClaim
            1,                      // countLimitPerUser
            30 ether,               // totalAmountLimit
            30 ether,               // initialFunds
            block.timestamp - 1,    // startTime
            block.timestamp + 1 days, // endTime
            root,                   // merkleRoot
            ""                      // ipfsCid (empty for test)
        );
        vm.stopPrank();

        bytes32[] memory proof0 = new bytes32[](2);
        proof0[0] = leaf1;
        proof0[1] = leaf2;

        // First claim succeeds
        vm.startPrank(claimer1);
        token.claimVoucher("VOUCHER001", "CODE001", proof0);

        // Second claim should fail (limit per user is 1)
        vm.expectRevert("Claim count reached limitation");
        token.claimVoucher("VOUCHER001", "CODE001", proof0);
        vm.stopPrank();
    }
}
