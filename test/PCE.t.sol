// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PCECommunityTokenV4} from "../src/PCECommunityTokenV4.sol";
import {PCEToken} from "../src/PCEToken.sol";
import {PCETokenV4} from "../src/PCETokenV4.sol";
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

contract PCECommunityTokenV2Test is Test {
    PCETokenV4 public pceToken;
    PCECommunityTokenV4 public token;
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

        vm.startPrank(owner);

        // 1. Deploy implementations
        PCECommunityTokenV4 pceCommunityTokenV4 = new PCECommunityTokenV4();

        PCEToken pceTokenV1 = new PCEToken();
        PCETokenV4 pceTokenV4Impl = new PCETokenV4(); // Use a different name for the implementation

        // 2. Deploy Minimal Beacon for Community Token
        MinimalBeacon pceCommunityTokenBeacon = new MinimalBeacon(address(pceCommunityTokenV4));

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
        pceTokenProxy.upgradeTo(address(pceTokenV4Impl)); // Upgrade to PCETokenV4 implementation

        // 6. Cast the proxy to the final version
        pceToken = PCETokenV4(address(pceTokenProxy));

        // Initial mint for token creation (assuming createToken needs owner balance)
        pceToken.mint(owner, 10000 * 10**18); // Mint some initial tokens to owner

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
        token = PCECommunityTokenV4(payable(tokenAddress)); // Cast to payable for proxy interaction
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
