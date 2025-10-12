// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PCECommunityTokenV8} from "../src/PCECommunityTokenV8.sol";
import {PCEToken} from "../src/PCEToken.sol";
import {PCETokenV8} from "../src/PCETokenV8.sol";
import {ExchangeAllowMethod} from "../src/lib/Enum.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Utils } from "../src/lib/Utils.sol";

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

// Minimal UUPS Proxy for testing
contract MinimalUUPSProxy {
    address public implementation;
    address public owner;

    constructor(address initialImplementation) {
        implementation = initialImplementation;
        owner = msg.sender; // Simplified ownership
    }

    // Allow upgrading the implementation (simplified for testing)
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
            // Copy msg.data. We take full control of memory in this inline assembly
            // block, so it will not interfere with Solidity's memory management.
            calldatacopy(0, 0, calldatasize())

            // Call the implementation.
            // out and outsize are 0 because we don't know the size yet.
            let result := delegatecall(gas(), _implementation, 0, calldatasize(), 0, 0)

            // Copy the returned data.
            returndatacopy(0, 0, returndatasize())

            switch result
            // delegatecall returns 0 on error.
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }
}

contract PCETest is Test {
    PCETokenV8 public pceToken;
    PCECommunityTokenV8 public token;
    MinimalBeacon public pceCommunityTokenBeacon;
    address public owner;
    address public user1;
    address public user2;
    uint256 public initialSupply = 1 ether;

    // Custom error definitions
    error NoTokensCreated();
    error TokenCreationFailed();

    function setUp() public {
        console2.log("========= setUp START ==========");
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);

        vm.startPrank(owner);

        // 1. Deploy implementations
        PCECommunityTokenV8 pceCommunityTokenV8 = new PCECommunityTokenV8();

        PCEToken pceTokenV1 = new PCEToken();
        PCETokenV8 pceTokenV8Impl = new PCETokenV8(); // Use a different name for the implementation

        // 2. Deploy Minimal Beacon for Community Token
        pceCommunityTokenBeacon = new MinimalBeacon(address(pceCommunityTokenV8));

        // 3. Deploy Minimal UUPS Proxy for PCEToken
        MinimalUUPSProxy pceTokenProxy = new MinimalUUPSProxy(address(pceTokenV1));

        // 4. Initialize the PCEToken proxy
        // Cast the proxy address to PCEToken interface to call initialize
        PCEToken pceTokenProxyInit = PCEToken(address(pceTokenProxy));
        pceTokenProxyInit.initialize(
            "PCE Token",
            "PCE",
            address(pceCommunityTokenBeacon),
            address(0x687C1D2dd0F422421BeF7aC2a52f50e858CAA867)
        );

        // 5. Perform upgrades (simulated)
        pceTokenProxy.upgradeTo(address(pceTokenV8Impl)); // Upgrade to PCETokenV8 implementation

        // 6. Cast the proxy to the final version
        pceToken = PCETokenV8(address(pceTokenProxy));

        // Initial mint for token creation (assuming createToken needs owner balance)
        pceToken.mint(owner, 10000 ether); // Mint some initial tokens to owner

        // Create token
        address[] memory incomeTargetTokens = new address[](0);
        address[] memory outgoTargetTokens = new address[](0);

        try pceToken.createToken(
            "PCE Community Token",
            "PCECT",
            1000 ether, // Amount of PCEToken to exchange
            1 ether, // Dilution factor (1:1)
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
            console2.log("Token creation successful"); // Updated log message
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
        console2.log("PCEToken proxy address:", address(pceToken));
        console2.log("Community Beacon address:", address(pceCommunityTokenBeacon));
        console2.log("Owner address:", owner);

        // Get the address of the created token
        address[] memory tokens = pceToken.getTokens();
        if (tokens.length == 0) revert NoTokensCreated();
        address tokenAddress = tokens[0];
        // The community token created will be a proxy pointing to the beacon's implementation
        // We need to interact with the community token *proxy*, not the implementation directly
        // Assuming createToken deploys a BeaconProxy for the community token
        // We need the *actual* address of the created community token proxy
        token = PCECommunityTokenV8(payable(tokenAddress)); // Cast to payable for proxy interaction
        console2.log("Community token proxy address:", tokenAddress);
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
        uint256 smallMintAmount = 100 ether;  // 100 tokens
        uint256 smallTransferAmount = 10 ether;  // 10 tokens
        _testTransfer("small", smallMintAmount, smallTransferAmount);
    }

    // Test that medium value transfers work correctly
    function testLargeValueTransfer() public {
        uint256 largeMintAmount = 10000000 ether;  // 10000000 tokens
        uint256 largeTransferAmount = 100000 ether;  // 100000 tokens
        _testTransfer("large", largeMintAmount, largeTransferAmount);
    }

    // Test swapTokens and getSwapRateBetweenTokens equivalence
    function testgetSwapRateBetweenTokens() public {
        console2.log("========= testgetSwapRateBetweenTokens START ==========");
        vm.startPrank(owner);
        address[] memory incomeTargetTokens = new address[](0);
        address[] memory outgoTargetTokens = new address[](0);

        // Create first token with 1:1 exchange rate
        pceToken.createToken(
            "First Community Token",
            "FCT",
            1000 ether, // Amount of PCEToken to exchange
            1 ether, // Dilution factor (1:1)
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
        );

        // Create second token with 2:1 exchange rate
        pceToken.createToken(
            "Second Community Token",
            "SCT",
            1000 ether, // Amount of PCEToken to exchange
            2 ether, // Dilution factor (2:1)
            2, // Decrease interval (days)
            9900, // After decrease BP (99%)
            2000, // Max increase of total supply BP (20%)
            1000, // Max increase BP (10%)
            2000, // Max usage BP (20%)
            200, // Change BP (2%)
            ExchangeAllowMethod.All, // Income exchange allow method
            ExchangeAllowMethod.All, // Outgo exchange allow method
            incomeTargetTokens,
            outgoTargetTokens
        );

        // Get all token addresses
        address[] memory tokens = pceToken.getTokens();
        address firstTokenAddress = tokens[1];
        address secondTokenAddress = tokens[2];
        PCECommunityTokenV8 firstToken = PCECommunityTokenV8(firstTokenAddress);
        PCECommunityTokenV8 secondToken = PCECommunityTokenV8(secondTokenAddress);

        // Mint tokens to user1 for testing
        firstToken.mint(user1, 1000 ether);
        secondToken.mint(user1, 1000 ether);
        vm.stopPrank();

        // check getSwapRateBetweenTokens
        uint256 rate1to1 = pceToken.getSwapRateBetweenTokens(firstTokenAddress, firstTokenAddress);
        assertEq(rate1to1, 1 ether);

        uint256 rate1to2 = pceToken.getSwapRateBetweenTokens(firstTokenAddress, secondTokenAddress);
        assertEq(rate1to2, 2 ether);

        uint256 rate2to1 = pceToken.getSwapRateBetweenTokens(secondTokenAddress, firstTokenAddress);
        assertEq(rate2to1, 0.5 ether);

        // check swapTokens
        assertEq(firstToken.balanceOf(user1), 1000 ether);
        assertEq(secondToken.balanceOf(user1), 1000 ether);

        vm.startPrank(user1);

        // swap 100 tokens from firstToken to secondToken
        // firstToken minus 100 tokens, secondToken plus 200 tokens
        firstToken.swapTokens(secondTokenAddress, 100 ether);

        assertEq(firstToken.balanceOf(user1), 900 ether);
        assertEq(secondToken.balanceOf(user1), 1200 ether);

        // swap 100 tokens from secondToken to firstToken
        // firstToken plus 50 tokens, secondToken minus 100 tokens
        secondToken.swapTokens(firstTokenAddress, 100 ether);

        assertEq(firstToken.balanceOf(user1), 950 ether);
        assertEq(secondToken.balanceOf(user1), 1100 ether);

        vm.stopPrank();
    }

    function testTransferFromWithAuthorization() public {
        console2.log("========= testTransferFromWithAuthorization START ==========");

        uint256 privateKeyOwner = 0x1234567890123456789012345678901234567890123456789012345678901234;
        address tokenOwner = vm.addr(privateKeyOwner);
        uint256 privateKeySpender = 0x2345678901234567890123456789012345678901234567890123456789012345;
        address spender = vm.addr(privateKeySpender);
        address to = address(0x5);

        // Create PCECommunityTokenV8 using PCETokenV8's createToken method

        address[] memory incomeTokens = new address[](0);
        address[] memory outgoTokens = new address[](0);

        vm.startPrank(address(this));
        pceToken.createToken(
            "PCE Community Token V8",
            "PCEV8",
            1000 ether, // Amount of PCEToken to exchange
            1 ether, // Dilution factor (1:1)
            1, // Decrease interval (days)
            9800, // After decrease BP (98%)
            1000, // Max increase of total supply BP (10%)
            500, // Max increase BP (5%)
            1000, // Max usage BP (10%)
            100, // Change BP (1%)
            ExchangeAllowMethod.All, // Income exchange allow method
            ExchangeAllowMethod.All, // Outgo exchange allow method
            incomeTokens,
            outgoTokens
        );
        vm.stopPrank();

        // Get the created token (it will be the last one in the list)
        address[] memory tokens = pceToken.getTokens();
        PCECommunityTokenV8 tokenV8 = PCECommunityTokenV8(tokens[tokens.length - 1]);

        // Mint tokens to tokenOwner and set up allowance
        tokenV8.mint(tokenOwner, 1000 ether);

        // V8: Spender doesn't need to hold any tokens now since from pays everything
        // No need to mint tokens to spender

        vm.prank(tokenOwner);
        tokenV8.approve(spender, 100 ether);

        // Prepare signature
        uint256 amount = 100 ether;
        uint256 validAfter = block.timestamp - 1; // Make sure it's already valid
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("test_nonce");

        bytes32 structHash = keccak256(abi.encode(
            tokenV8.TRANSFER_FROM_WITH_AUTHORIZATION_TYPEHASH(),
            spender,
            tokenOwner,  // from
            to,
            amount,
            validAfter,
            validBefore,
            nonce
        ));

        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            tokenV8.DOMAIN_SEPARATOR(),
            structHash
        ));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKeySpender, digest);

        uint256 initialOwnerBalance = tokenV8.balanceOf(tokenOwner);
        uint256 initialSpenderBalance = tokenV8.balanceOf(spender);
        uint256 initialToBalance = tokenV8.balanceOf(to);
        uint256 initialExecutorBalance = tokenV8.balanceOf(user1);
        uint256 initialAllowance = tokenV8.allowance(tokenOwner, spender);


        // Execute transferFromWithAuthorization
        vm.prank(user1); // Meta transaction executor
        tokenV8.transferFromWithAuthorization(
            spender,
            tokenOwner,  // from
            to,
            amount,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s
        );

        uint256 finalOwnerBalance = tokenV8.balanceOf(tokenOwner);
        uint256 finalSpenderBalance = tokenV8.balanceOf(spender);
        uint256 finalToBalance = tokenV8.balanceOf(to);
        uint256 finalExecutorBalance = tokenV8.balanceOf(user1);
        uint256 finalAllowance = tokenV8.allowance(tokenOwner, spender);

        // V8: Verify results - from (owner) pays both amount and fee, spender signs the authorization
        assertTrue(finalOwnerBalance < initialOwnerBalance, "Owner balance should decrease (amount + fee)");
        assertEq(finalSpenderBalance, initialSpenderBalance, "Spender balance should stay the same");
        assertEq(finalToBalance, initialToBalance + amount, "To balance should increase by amount");
        assertTrue(finalExecutorBalance > initialExecutorBalance, "Executor should receive fee");
        assertEq(finalAllowance, initialAllowance - amount, "Allowance should decrease by amount");
        assertTrue(tokenV8.authorizationState(spender, nonce), "Nonce should be marked as used for spender");

    }

    function testInfinityApproveFlag() public {
        console2.log("========= testInfinityApproveFlag START ==========");

        uint256 privateKeyOwner = 0x1234567890123456789012345678901234567890123456789012345678901234;
        address tokenOwner = vm.addr(privateKeyOwner);
        address spender = address(0x4);
        address to = address(0x5);

        // Get the existing V8 token from setUp
        address[] memory tokens = pceToken.getTokens();
        PCECommunityTokenV8 tokenV8 = PCECommunityTokenV8(tokens[tokens.length - 1]);

        // Mint tokens to tokenOwner
        tokenV8.mint(tokenOwner, 1000 ether);

        // Test 1: Normal transferFrom without infinity approve flag (should fail)
        uint256 amount = 100 ether;
        vm.prank(spender);
        vm.expectRevert();
        tokenV8.transferFrom(tokenOwner, to, amount);

        // Test 2: Set infinity approve flag
        vm.prank(tokenOwner);
        tokenV8.setInfinityApproveFlag(spender, true);

        // Verify flag is set
        assertTrue(tokenV8.getInfinityApproveFlag(tokenOwner, spender), "Infinity approve flag should be set");

        // Test 3: transferFrom with infinity approve flag (should succeed)
        uint256 initialOwnerBalance = tokenV8.balanceOf(tokenOwner);
        uint256 initialToBalance = tokenV8.balanceOf(to);

        vm.prank(spender);
        bool success = tokenV8.transferFrom(tokenOwner, to, amount);

        assertTrue(success, "Transfer should succeed with infinity approve flag");
        assertTrue(tokenV8.balanceOf(tokenOwner) != initialOwnerBalance, "Owner balance should change");
        assertEq(tokenV8.balanceOf(to), initialToBalance + amount, "To balance should increase");

        // Test 4: Disable infinity approve flag
        vm.prank(tokenOwner);
        tokenV8.setInfinityApproveFlag(spender, false);

        // Verify flag is unset
        assertFalse(tokenV8.getInfinityApproveFlag(tokenOwner, spender), "Infinity approve flag should be unset");

        // Test 5: transferFrom without infinity approve flag (should fail again)
        vm.prank(spender);
        vm.expectRevert();
        tokenV8.transferFrom(tokenOwner, to, amount);
    }

    function testSetInfinityApproveFlagWithAuthorization() public {
        console2.log("========= testSetInfinityApproveFlagWithAuthorization START ==========");

        uint256 privateKeyOwner = 0x1234567890123456789012345678901234567890123456789012345678901234;
        address tokenOwner = vm.addr(privateKeyOwner);
        address spender = address(0x4);

        // Get existing V8 token from setUp
        address[] memory tokens = pceToken.getTokens();
        PCECommunityTokenV8 tokenV8 = PCECommunityTokenV8(tokens[tokens.length - 1]);

        // Mint tokens to tokenOwner for fee payment
        tokenV8.mint(tokenOwner, 1000 ether);

        // Prepare signature for setInfinityApproveFlagWithAuthorization
        bool flag = true;
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("test_nonce_infinity_approve");

        bytes32 structHash = keccak256(abi.encode(
            tokenV8.SET_INFINITY_APPROVE_FLAG_WITH_AUTHORIZATION_TYPEHASH(),
            tokenOwner,
            spender,
            flag,
            validAfter,
            validBefore,
            nonce
        ));

        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            tokenV8.DOMAIN_SEPARATOR(),
            structHash
        ));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKeyOwner, digest);

        // Execute setInfinityApproveFlagWithAuthorization
        vm.prank(user1); // Meta transaction executor
        tokenV8.setInfinityApproveFlagWithAuthorization(
            tokenOwner,
            spender,
            flag,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s
        );

        // Verify flag is set
        assertTrue(tokenV8.getInfinityApproveFlag(tokenOwner, spender), "Infinity approve flag should be set");
        assertTrue(tokenV8.authorizationState(tokenOwner, nonce), "Nonce should be marked as used");
    }
}
