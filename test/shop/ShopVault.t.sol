// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ShopVault } from "src/shop/ShopVault.sol";
import { ShopVaultFactory } from "src/shop/ShopVaultFactory.sol";
import { CappedPaymentAuthorizer } from "src/shop/CappedPaymentAuthorizer.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ShopVaultTest is Test {
    ShopVaultFactory factory;
    MockERC20 token;
    MockERC20 other;
    address owner = makeAddr("owner");
    address admin = makeAddr("admin");
    address manager = makeAddr("manager");
    address staff = makeAddr("staff");
    address stranger = makeAddr("stranger");
    bytes32 shopId = keccak256("shop-1");

    function setUp() public {
        factory = new ShopVaultFactory(owner);
        token = new MockERC20();
        other = new MockERC20();
        vm.prank(owner);
        factory.setCommunityAdmin(address(token), admin);
        vm.prank(manager);
        factory.registerShop(address(token), shopId, manager);
    }

    function test_PredictMatchesDeployed() public {
        address predicted = factory.predict(address(token), shopId);
        bytes32 s = keccak256(abi.encode(address(token), shopId));
        assertEq(predicted, vm.computeCreate2Address(s, factory.initCodeHash(), address(factory)));
        assertEq(predicted.code.length, 0);
        assertEq(factory.deployVault(address(token), shopId), predicted);
        assertGt(predicted.code.length, 0);
        assertEq(ShopVault(payable(predicted)).controller(), address(factory));
    }

    function test_ShopPolicy_DeployOnFirstWithdraw() public {
        address vault = factory.predict(address(token), shopId);
        token.mint(vault, 100);
        vm.prank(manager);
        factory.withdrawERC20(address(token), shopId, address(token), manager, 60);
        assertEq(token.balanceOf(manager), 60);

        vm.prank(stranger);
        vm.expectRevert(ShopVaultFactory.NotAuthorized.selector);
        factory.withdrawERC20(address(token), shopId, address(token), stranger, 1);

        vm.prank(admin);
        vm.expectRevert(ShopVaultFactory.NotAuthorized.selector);
        factory.withdrawERC20(address(token), shopId, address(token), admin, 1);

        vm.prank(manager);
        factory.setShopWithdrawer(address(token), shopId, staff, true);
        vm.prank(staff);
        factory.withdrawERC20(address(token), shopId, address(token), staff, 40);
        assertEq(token.balanceOf(staff), 40);
    }

    function test_CommunityPolicy() public {
        vm.prank(stranger);
        vm.expectRevert(ShopVaultFactory.NotCommunityAdmin.selector);
        factory.setWithdrawPolicy(address(token), ShopVaultFactory.WithdrawPolicy.COMMUNITY);
        vm.prank(admin);
        factory.setWithdrawPolicy(address(token), ShopVaultFactory.WithdrawPolicy.COMMUNITY);

        address vault = factory.predict(address(token), shopId);
        token.mint(vault, 100);
        vm.prank(manager);
        vm.expectRevert(ShopVaultFactory.NotAuthorized.selector);
        factory.withdrawERC20(address(token), shopId, address(token), manager, 1);
        vm.prank(admin);
        factory.withdrawERC20(address(token), shopId, address(token), admin, 100);
        assertEq(token.balanceOf(admin), 100);
    }

    function test_RescueRandomERC20AndNative() public {
        address vault = factory.predict(address(token), shopId);
        other.mint(vault, 5);
        vm.deal(vault, 1 ether);
        vm.startPrank(manager);
        factory.withdrawERC20(address(token), shopId, address(other), stranger, 5);
        factory.withdrawNative(address(token), shopId, stranger, 1 ether);
        vm.stopPrank();
        assertEq(other.balanceOf(stranger), 5);
        assertEq(stranger.balance, 1 ether);
    }

    function test_VaultDirectCallReverts() public {
        address vault = factory.deployVault(address(token), shopId);
        vm.prank(manager);
        vm.expectRevert(ShopVault.NotController.selector);
        ShopVault(payable(vault)).withdrawNative(manager, 0);
        vm.expectRevert(ShopVault.AlreadyInitialized.selector);
        ShopVault(payable(vault)).initialize(address(token), shopId, stranger);
    }
}

contract CappedPaymentAuthorizerTest is Test {
    CappedPaymentAuthorizer auth;
    MockERC20 token;
    uint256 pk = 0xA11CE;
    address customer;
    address vault = makeAddr("vault");

    function setUp() public {
        auth = new CappedPaymentAuthorizer();
        token = new MockERC20();
        customer = vm.addr(pk);
        token.mint(customer, 1000);
        vm.prank(customer);
        token.approve(address(auth), type(uint256).max);
    }

    function _sign(uint256 maxAmount, uint256 validBefore, bytes32 nonce) internal view returns (bytes memory) {
        bytes32 d = auth.hashAuthorization(address(token), customer, maxAmount, validBefore, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    function test_PayWithinCap_ThenReplayReverts() public {
        uint256 vb = block.timestamp + 60;
        bytes memory sig = _sign(500, vb, bytes32(uint256(1)));
        auth.pay(address(token), customer, 500, vb, bytes32(uint256(1)), vault, 300, sig);
        assertEq(token.balanceOf(vault), 300);
        vm.expectRevert(CappedPaymentAuthorizer.NonceUsed.selector);
        auth.pay(address(token), customer, 500, vb, bytes32(uint256(1)), vault, 1, sig);
    }

    function test_OverCapReverts() public {
        uint256 vb = block.timestamp + 60;
        bytes memory sig = _sign(500, vb, bytes32(uint256(2)));
        vm.expectRevert(CappedPaymentAuthorizer.OverCap.selector);
        auth.pay(address(token), customer, 500, vb, bytes32(uint256(2)), vault, 501, sig);
    }

    function test_ExpiredAndBadSigRevert() public {
        uint256 vb = block.timestamp + 60;
        bytes memory sig = _sign(500, vb, bytes32(uint256(3)));
        vm.expectRevert(CappedPaymentAuthorizer.InvalidSignature.selector);
        auth.pay(address(token), customer, 600, vb, bytes32(uint256(3)), vault, 1, sig);
        vm.warp(vb);
        vm.expectRevert(CappedPaymentAuthorizer.Expired.selector);
        auth.pay(address(token), customer, 500, vb, bytes32(uint256(3)), vault, 1, sig);
    }
}
