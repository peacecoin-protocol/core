// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PCECommunityToken} from "../src/PCECommunityToken.sol";
import {PCECommunityTokenV2} from "../src/PCECommunityTokenV2.sol";
import {PCECommunityTokenV3} from "../src/PCECommunityTokenV3.sol";
import {PCEToken} from "../src/PCEToken.sol";
import {PCETokenV2} from "../src/PCETokenV2.sol";
import {PCETokenV3} from "../src/PCETokenV3.sol";
import {ExchangeAllowMethod} from "../src/lib/Enum.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract PCECommunityTokenV2Test is Test {
    PCETokenV3 public pceToken;
    PCECommunityTokenV3 public token;
    address public owner;
    address public user1;
    address public user2;
    uint256 public initialSupply = 10 ** 18;

    // Custom error definitions
    error NoTokensCreated();
    error TokenCreationFailed();

    function setUp() public {
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);

        // Deploy using OpenZeppelin Upgrades library
        vm.startPrank(owner);

        // Deploy PCECommunityToken beacon
        address pceCommunityTokenBeacon = Upgrades.deployBeacon(
            "PCECommunityToken.sol:PCECommunityToken",
            owner
        );

        // Deploy PCEToken UUPS proxy
        address pceTokenProxy = Upgrades.deployUUPSProxy(
            "PCEToken.sol:PCEToken",
            abi.encodeCall(
                PCEToken.initialize,
                ("PCE Token", "PCE", pceCommunityTokenBeacon, address(0x687C1D2dd0F422421BeF7aC2a52f50e858CAA867))
            )
        );

        // Upgrade to V2
        Upgrades.upgradeBeacon(pceCommunityTokenBeacon, "PCECommunityTokenV2.sol:PCECommunityTokenV2");
        Upgrades.upgradeProxy(pceTokenProxy, "PCETokenV2.sol:PCETokenV2", "");

        // Upgrade to V3
        Upgrades.upgradeBeacon(pceCommunityTokenBeacon, "PCECommunityTokenV3.sol:PCECommunityTokenV3");
        Upgrades.upgradeProxy(pceTokenProxy, "PCETokenV3.sol:PCETokenV3", "");

        // Cast as PCEToken
        pceToken = PCETokenV3(pceTokenProxy);

        // Create token
        address[] memory incomeTargetTokens = new address[](0);
        address[] memory outgoTargetTokens = new address[](0);

        try pceToken.createToken(
            "PCE Community Token",
            "PCECT",
            1000 * 10**18, // Amount of PCEToken to exchange
            10**18, // Dilution factor (1:1)
            1, // Decrease interval (days)
            9800, // After decrease BP (98%)
            1000, // Max increase of total supply BP (10%)
            500, // Max increase BP (5%)
            1000, // Max usage BP (10%)
            100, // Change BP (1%)
            ExchangeAllowMethod.All, // Income exchange allow method
            ExchangeAllowMethod.All, // Outgo exchange allow method
            incomeTargetTokens,
            outgoTargetTokens
        ) {
            console2.log("Token creation successful with V1");
        } catch Error(string memory reason) {
            console2.log("Token creation failed with reason:", reason);
            revert(reason);
        } catch (bytes memory lowLevelData) {
            console2.log("Token creation failed with no reason");
            console2.logBytes(lowLevelData);
            revert TokenCreationFailed();
        }

        vm.stopPrank();

        // Add debug information
        console2.log("PCEToken address:", address(pceToken));
        console2.log("Beacon address:", pceCommunityTokenBeacon);
        console2.log("Owner address:", owner);

        // Get the address of the created token
        address[] memory tokens = pceToken.getTokens();
        if (tokens.length == 0) revert NoTokensCreated();
        address tokenAddress = tokens[0];
        token = PCECommunityTokenV3(tokenAddress);
        console2.log("Community token address:", tokenAddress);
    }

    // Common test function
    function _testTransfer(
        string memory testName,
        uint256 mintAmount,
        uint256 transferAmount
    ) internal {
        // Mint tokens
        vm.startPrank(owner);
        token.mint(owner, mintAmount);
        console2.log("Minted %s tokens to owner: %s", testName, mintAmount);
        vm.stopPrank();

        // Mint tokens to user1
        vm.startPrank(owner);
        token.mint(user1, mintAmount);
        console2.log("Minted %s tokens to user1: %s", testName, mintAmount);
        vm.stopPrank();

        vm.startPrank(user1);
        console2.log("Attempting to transfer %s amount before time warp: %s", testName, transferAmount);

        bool transferSuccessBefore = true;
        try token.transfer(user2, transferAmount) {
            // Transfer succeeded
            transferSuccessBefore = true;
            console2.log("%s transfer before time warp succeeded", testName);

            // Check balances after transfer
            console2.log("User1 balance after transfer before time warp: %s", token.balanceOf(user1));
            console2.log("User2 balance after transfer before time warp: %s", token.balanceOf(user2));
        } catch Error(string memory reason) {
            // Transfer failed with reason
            transferSuccessBefore = false;
            console2.log("%s transfer before time warp failed with reason: %s", testName, reason);
        } catch (bytes memory lowLevelData) {
            // Transfer failed with no reason
            transferSuccessBefore = false;
            console2.log("%s transfer before time warp failed with no reason", testName);
            console2.logBytes(lowLevelData);
        }
        vm.stopPrank();

        // Advance time by 1 day
        vm.warp(block.timestamp + 1 days);
        console2.log("Warped time forward 1 day");

        // Check balances
        console2.log("Owner balance before: %s", token.balanceOf(owner));
        console2.log("User1 balance before: %s", token.balanceOf(user1));
        console2.log("User2 balance before: %s", token.balanceOf(user2));

        // Transfer from user1 to user2
        vm.startPrank(user1);
        console2.log("Attempting to transfer %s amount after time warp: %s", testName, transferAmount);

        bool transferSuccessAfter = true;
        try token.transfer(user2, transferAmount) {
            // Transfer succeeded
            transferSuccessAfter = true;
            console2.log("%s transfer after time warp succeeded", testName);

            // Check balances after transfer
            console2.log("User1 balance after transfer after time warp: %s", token.balanceOf(user1));
            console2.log("User2 balance after transfer after time warp: %s", token.balanceOf(user2));
        } catch Error(string memory reason) {
            // Transfer failed with reason
            transferSuccessAfter = false;
            console2.log("%s transfer after time warp failed with reason: %s", testName, reason);
        } catch (bytes memory lowLevelData) {
            // Transfer failed with no reason
            transferSuccessAfter = false;
            console2.log("%s transfer after time warp failed with no reason", testName);
            console2.logBytes(lowLevelData);
        }
        vm.stopPrank();

        // Check if the result is as expected
        // Fail the test if transfer fails
        if (!transferSuccessBefore) {
            string memory errorMsg = string(
                abi.encodePacked(
                    testName,
                    " transfer before time warp failed, which is unexpected"
                )
            );
            assertTrue(transferSuccessBefore, errorMsg);
        }

        if (!transferSuccessAfter) {
            string memory errorMsg = string(
                abi.encodePacked(
                    testName,
                    " transfer after time warp failed, which is unexpected"
                )
            );
            assertTrue(transferSuccessAfter, errorMsg);
        }
    }

    // Test that small value transfers work correctly
    function testSmallValueTransfer() public {
        uint256 smallMintAmount = 100 * 10**18;  // 100 tokens
        uint256 smallTransferAmount = 10 * 10**18;  // 10 tokens
        _testTransfer("small", smallMintAmount, smallTransferAmount);
    }

    // Test that medium value transfers work correctly
    function testLargeValueTransfer() public {
        uint256 largeMintAmount = 10000000 * 10**18;  // 10000000 tokens
        uint256 largeTransferAmount = 100000 * 10**18;  // 100000 tokens
        _testTransfer("large", largeMintAmount, largeTransferAmount);
    }
}
