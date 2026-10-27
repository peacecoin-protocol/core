// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { ShopVaultFactory } from "src/shop/ShopVaultFactory.sol";
import { MockERC20 } from "./ShopVault.t.sol";

contract ShopVaultFactorySigTest is Test {
    ShopVaultFactory factory;
    MockERC20 token;
    address owner = makeAddr("owner");
    address relayer = makeAddr("relayer");
    address to = makeAddr("to");
    uint256 managerPk = 0xA1;
    uint256 adminPk = 0xA2;
    uint256 staffPk = 0xA3;
    uint256 strangerPk = 0xA4;
    address manager;
    address admin;
    address staff;
    bytes32 shopId = keccak256("shop-1");
    uint256 deadline;

    function setUp() public {
        manager = vm.addr(managerPk);
        admin = vm.addr(adminPk);
        staff = vm.addr(staffPk);
        factory = new ShopVaultFactory(owner);
        token = new MockERC20();
        vm.prank(owner);
        factory.setCommunityAdmin(address(token), admin);
        deadline = block.timestamp + 1 hours;
    }

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", factory.domainSeparator(), structHash));
    }

    function _sign(uint256 pk, bytes32 structHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(structHash));
        return abi.encodePacked(r, s, v);
    }

    function _regHash(address m, uint256 dl) internal view returns (bytes32) {
        return keccak256(abi.encode(factory.REGISTER_SHOP_TYPEHASH(), address(token), shopId, m, dl));
    }

    function _register() internal {
        vm.prank(relayer);
        factory.registerShopWithSig(
            address(token), shopId, manager, deadline, _sign(managerPk, _regHash(manager, deadline))
        );
    }

    function test_RegisterShopWithSig() public {
        bytes memory bad = _sign(strangerPk, _regHash(manager, deadline));
        vm.expectRevert(ShopVaultFactory.NotShopManager.selector);
        factory.registerShopWithSig(address(token), shopId, manager, deadline, bad);

        _register();
        assertEq(factory.shopManager(address(token), shopId), manager);

        bytes memory sig = _sign(managerPk, _regHash(manager, deadline));
        vm.expectRevert(ShopVaultFactory.AlreadyRegistered.selector);
        factory.registerShopWithSig(address(token), shopId, manager, deadline, sig);

        vm.warp(deadline + 1);
        vm.expectRevert(ShopVaultFactory.SignatureExpired.selector);
        factory.registerShopWithSig(address(token), keccak256("shop-2"), manager, deadline, sig);
    }

    function _policyHash(uint8 p, uint256 dl, bytes32 n) internal view returns (bytes32) {
        return keccak256(abi.encode(factory.SET_WITHDRAW_POLICY_TYPEHASH(), address(token), p, dl, n));
    }

    function test_SetWithdrawPolicyWithSig() public {
        bytes32 n = bytes32(uint256(1));
        bytes memory bad = _sign(strangerPk, _policyHash(1, deadline, n));
        vm.expectRevert(ShopVaultFactory.NotCommunityAdmin.selector);
        factory.setWithdrawPolicyWithSig(address(token), ShopVaultFactory.WithdrawPolicy.COMMUNITY, deadline, n, bad);

        bytes memory sig = _sign(adminPk, _policyHash(1, deadline, n));
        vm.prank(relayer);
        factory.setWithdrawPolicyWithSig(address(token), ShopVaultFactory.WithdrawPolicy.COMMUNITY, deadline, n, sig);
        assertEq(uint8(factory.withdrawPolicy(address(token))), 1);

        vm.expectRevert(ShopVaultFactory.NonceAlreadyUsed.selector);
        factory.setWithdrawPolicyWithSig(address(token), ShopVaultFactory.WithdrawPolicy.COMMUNITY, deadline, n, sig);

        bytes32 n2 = bytes32(uint256(2));
        bytes memory sig2 = _sign(adminPk, _policyHash(0, deadline, n2));
        vm.warp(deadline + 1);
        vm.expectRevert(ShopVaultFactory.SignatureExpired.selector);
        factory.setWithdrawPolicyWithSig(address(token), ShopVaultFactory.WithdrawPolicy.SHOP, deadline, n2, sig2);
    }

    function _withdrawerHash(address a, bool ok, uint256 dl, bytes32 n) internal view returns (bytes32) {
        return keccak256(abi.encode(factory.SET_SHOP_WITHDRAWER_TYPEHASH(), address(token), shopId, a, ok, dl, n));
    }

    function test_SetShopWithdrawerWithSig() public {
        _register();
        bytes32 n = bytes32(uint256(1));
        bytes memory bad = _sign(strangerPk, _withdrawerHash(staff, true, deadline, n));
        vm.expectRevert(ShopVaultFactory.NotShopManager.selector);
        factory.setShopWithdrawerWithSig(address(token), shopId, staff, true, deadline, n, bad);

        bytes memory sig = _sign(managerPk, _withdrawerHash(staff, true, deadline, n));
        factory.setShopWithdrawerWithSig(address(token), shopId, staff, true, deadline, n, sig);
        assertTrue(factory.shopWithdrawer(address(token), shopId, staff));

        vm.expectRevert(ShopVaultFactory.NonceAlreadyUsed.selector);
        factory.setShopWithdrawerWithSig(address(token), shopId, staff, true, deadline, n, sig);

        bytes32 n2 = bytes32(uint256(2));
        bytes memory sig2 = _sign(managerPk, _withdrawerHash(staff, false, deadline, n2));
        vm.warp(deadline + 1);
        vm.expectRevert(ShopVaultFactory.SignatureExpired.selector);
        factory.setShopWithdrawerWithSig(address(token), shopId, staff, false, deadline, n2, sig2);
    }

    function _erc20Hash(uint256 amt, uint256 dl, bytes32 n) internal view returns (bytes32) {
        return keccak256(
            abi.encode(factory.WITHDRAW_ERC20_TYPEHASH(), address(token), shopId, address(token), to, amt, dl, n)
        );
    }

    function test_WithdrawERC20WithSig() public {
        _register();
        token.mint(factory.predict(address(token), shopId), 100);
        bytes32 n = bytes32(uint256(1));

        bytes memory bad = _sign(strangerPk, _erc20Hash(10, deadline, n));
        vm.expectRevert(ShopVaultFactory.NotAuthorized.selector);
        factory.withdrawERC20WithSig(address(token), shopId, address(token), to, 10, deadline, n, bad);

        bytes memory sig = _sign(managerPk, _erc20Hash(10, deadline, n));
        vm.prank(relayer);
        factory.withdrawERC20WithSig(address(token), shopId, address(token), to, 10, deadline, n, sig);
        assertEq(token.balanceOf(to), 10);

        vm.expectRevert(ShopVaultFactory.NonceAlreadyUsed.selector);
        factory.withdrawERC20WithSig(address(token), shopId, address(token), to, 10, deadline, n, sig);

        // tampered amount -> recovers a different signer
        bytes32 n2 = bytes32(uint256(2));
        bytes memory sig2 = _sign(managerPk, _erc20Hash(10, deadline, n2));
        vm.expectRevert(ShopVaultFactory.NotAuthorized.selector);
        factory.withdrawERC20WithSig(address(token), shopId, address(token), to, 90, deadline, n2, sig2);

        vm.warp(deadline + 1);
        vm.expectRevert(ShopVaultFactory.SignatureExpired.selector);
        factory.withdrawERC20WithSig(address(token), shopId, address(token), to, 10, deadline, n2, sig2);
    }

    function _nativeHash(uint256 amt, uint256 dl, bytes32 n) internal view returns (bytes32) {
        return keccak256(abi.encode(factory.WITHDRAW_NATIVE_TYPEHASH(), address(token), shopId, to, amt, dl, n));
    }

    function test_WithdrawNativeWithSig() public {
        _register();
        vm.deal(factory.predict(address(token), shopId), 1 ether);
        bytes32 n = bytes32(uint256(1));

        bytes memory bad = _sign(strangerPk, _nativeHash(1 ether, deadline, n));
        vm.expectRevert(ShopVaultFactory.NotAuthorized.selector);
        factory.withdrawNativeWithSig(address(token), shopId, to, 1 ether, deadline, n, bad);

        bytes memory sig = _sign(managerPk, _nativeHash(0.5 ether, deadline, n));
        vm.prank(relayer);
        factory.withdrawNativeWithSig(address(token), shopId, to, 0.5 ether, deadline, n, sig);
        assertEq(to.balance, 0.5 ether);

        vm.expectRevert(ShopVaultFactory.NonceAlreadyUsed.selector);
        factory.withdrawNativeWithSig(address(token), shopId, to, 0.5 ether, deadline, n, sig);

        bytes32 n2 = bytes32(uint256(2));
        bytes memory sig2 = _sign(managerPk, _nativeHash(0.5 ether, deadline, n2));
        vm.warp(deadline + 1);
        vm.expectRevert(ShopVaultFactory.SignatureExpired.selector);
        factory.withdrawNativeWithSig(address(token), shopId, to, 0.5 ether, deadline, n2, sig2);
    }

    function test_InvalidSignatureBytesReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 3));
        factory.registerShopWithSig(address(token), shopId, manager, deadline, hex"010203");
    }
}
