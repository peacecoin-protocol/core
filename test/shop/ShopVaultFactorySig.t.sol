// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { ShopVaultFactory } from "src/shop/ShopVaultFactory.sol";
import { ShopFixture } from "./ShopVault.t.sol";

contract ShopVaultFactorySigTest is ShopFixture {
    address to = makeAddr("to");
    uint256 deadline;

    function setUp() public override {
        super.setUp();
        deadline = block.timestamp + 1 hours;
    }

    function _regHash(ShopVaultFactory.RegisterParams memory p, uint256 dl) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                REGISTER_SHOP_TYPEHASH,
                p.token,
                p.shopId,
                p.groupId,
                uint8(p.mode),
                p.ratioPct,
                p.cap,
                p.periodOffset,
                p.termsHash,
                dl
            )
        );
    }

    function _registerWithSig() internal returns (ShopVaultFactory.RegisterParams memory p) {
        p = _params(shopId, ShopVaultFactory.ReceiveMode.SPLIT, 100, 50_000 ether);
        vm.prank(relayer);
        factory.registerShopWithSig(p, deadline, _sign(managerPk, _regHash(p, deadline)));
    }

    function test_RegisterShopWithSig() public {
        ShopVaultFactory.RegisterParams memory p = _registerWithSig();
        assertEq(factory.groupOwner(groupId), manager);
        ShopVaultFactory.Shop memory s = factory.getShop(address(token), shopId);
        assertEq(s.ratioPct, 100);
        assertEq(s.cap, 50_000 ether);
        assertEq(s.periodOffset, OFFSET);

        bytes memory sig = _sign(managerPk, _regHash(p, deadline));
        vm.expectRevert(ShopVaultFactory.AlreadyRegistered.selector);
        factory.registerShopWithSig(p, deadline, sig);

        // tampered config -> different signer -> not the group owner
        ShopVaultFactory.RegisterParams memory q = _params(keccak256("shop-2"), ShopVaultFactory.ReceiveMode.SHOP, 0, 0);
        bytes memory sig2 = _sign(managerPk, _regHash(q, deadline));
        q.mode = ShopVaultFactory.ReceiveMode.COMMUNITY;
        q.ratioPct = 100;
        q.termsHash = terms;
        vm.expectRevert(ShopVaultFactory.NotGroupOwner.selector);
        factory.registerShopWithSig(q, deadline, sig2);

        vm.warp(deadline + 1);
        vm.expectRevert(ShopVaultFactory.SignatureExpired.selector);
        factory.registerShopWithSig(q, deadline, sig2);
    }

    function test_SetCommunityConfigWithSig() public {
        bytes32 n = bytes32(uint256(1));
        bytes32 h =
            keccak256(abi.encode(SET_COMMUNITY_CONFIG_TYPEHASH, address(token), true, 10 ether, terms, deadline, n));
        vm.expectRevert(ShopVaultFactory.NotCommunityAdmin.selector);
        factory.setCommunityConfigWithSig(address(token), true, 10 ether, terms, deadline, n, _sign(strangerPk, h));

        bytes memory sig = _sign(adminPk, h);
        vm.prank(relayer);
        factory.setCommunityConfigWithSig(address(token), true, 10 ether, terms, deadline, n, sig);
        (bool allow, uint256 maxCap, bytes32 th) = factory.communityConfig(address(token));
        assertTrue(allow);
        assertEq(maxCap, 10 ether);
        assertEq(th, terms);

        vm.expectRevert(ShopVaultFactory.NonceAlreadyUsed.selector);
        factory.setCommunityConfigWithSig(address(token), true, 10 ether, terms, deadline, n, sig);
    }

    function test_PermissionsAndPayoutWithSig() public {
        _registerWithSig();
        bytes32 n = bytes32(uint256(1));
        uint8 w = PERM_WITHDRAW;
        bytes32 h = keccak256(abi.encode(SET_SHOP_PERMISSION_TYPEHASH, address(token), shopId, staff, w, deadline, n));
        vm.expectRevert(ShopVaultFactory.NotAuthorized.selector);
        factory.setShopPermissionWithSig(address(token), shopId, staff, w, deadline, n, _sign(strangerPk, h));
        factory.setShopPermissionWithSig(address(token), shopId, staff, w, deadline, n, _sign(managerPk, h));
        assertTrue(factory.hasPermission(address(token), shopId, staff, w));

        bytes32 n3 = bytes32(uint256(3));
        bytes32 hg = keccak256(abi.encode(SET_GROUP_PERMISSION_TYPEHASH, groupId, staff, w, deadline, n3));
        factory.setGroupPermissionWithSig(groupId, staff, w, deadline, n3, _sign(managerPk, hg));
        assertEq(factory.groupPermission(groupId, staff), w);

        bytes32 hp = keccak256(abi.encode(SET_PAYOUT_TYPEHASH, address(token), shopId, payout, deadline, n));
        vm.expectRevert(ShopVaultFactory.NotGroupOwner.selector);
        factory.setPayoutWithSig(address(token), shopId, payout, deadline, n, _sign(staffPk, hp));
        bytes memory sig = _sign(managerPk, hp);
        // the same nonce was already used by the manager for the shop permission
        vm.expectRevert(ShopVaultFactory.NonceAlreadyUsed.selector);
        factory.setPayoutWithSig(address(token), shopId, payout, deadline, n, sig);
        bytes32 n2 = bytes32(uint256(2));
        hp = keccak256(abi.encode(SET_PAYOUT_TYPEHASH, address(token), shopId, payout, deadline, n2));
        factory.setPayoutWithSig(address(token), shopId, payout, deadline, n2, _sign(managerPk, hp));
        assertEq(factory.payoutOf(address(token), shopId), payout);
    }

    function test_WithdrawSharesWithSig() public {
        _registerWithSig();
        _pay(60_000 ether);
        vm.prank(manager);
        factory.setShopPermission(address(token), shopId, staff, PERM_WITHDRAW);

        bytes32 n = bytes32(uint256(1));
        bytes32 h =
            keccak256(abi.encode(WITHDRAW_SHOP_SHARE_TYPEHASH, address(token), shopId, 10_000 ether, deadline, n));
        vm.expectRevert(ShopVaultFactory.NotAuthorized.selector);
        factory.withdrawShopShareWithSig(address(token), shopId, 10_000 ether, deadline, n, _sign(strangerPk, h));
        bytes memory sig = _sign(staffPk, h);
        vm.prank(relayer);
        factory.withdrawShopShareWithSig(address(token), shopId, 10_000 ether, deadline, n, sig);
        assertEq(token.balanceOf(manager), 10_000 ether); // to the owner (payout), not the staff
        vm.expectRevert(ShopVaultFactory.NonceAlreadyUsed.selector);
        factory.withdrawShopShareWithSig(address(token), shopId, 10_000 ether, deadline, n, sig);

        bytes32 hc = keccak256(
            abi.encode(WITHDRAW_COMMUNITY_SHARE_TYPEHASH, address(token), shopId, to, 50_000 ether, deadline, n)
        );
        vm.expectRevert(ShopVaultFactory.NotCommunityAdmin.selector);
        factory.withdrawCommunityShareWithSig(
            address(token), shopId, to, 50_000 ether, deadline, n, _sign(managerPk, hc)
        );
        factory.withdrawCommunityShareWithSig(address(token), shopId, to, 50_000 ether, deadline, n, _sign(adminPk, hc));
        assertEq(token.balanceOf(to), 50_000 ether);

        vm.warp(deadline + 1);
        bytes32 n2 = bytes32(uint256(2));
        bytes32 h2 = keccak256(abi.encode(WITHDRAW_SHOP_SHARE_TYPEHASH, address(token), shopId, 1, deadline, n2));
        vm.expectRevert(ShopVaultFactory.SignatureExpired.selector);
        factory.withdrawShopShareWithSig(address(token), shopId, 1, deadline, n2, _sign(managerPk, h2));
    }

    function test_RescueWithSig() public {
        _registerWithSig();
        vm.deal(_vault(), 1 ether);
        bytes32 n = bytes32(uint256(1));
        bytes32 h = keccak256(abi.encode(RESCUE_TYPEHASH, address(token), shopId, address(0), to, 1 ether, deadline, n));
        factory.rescueWithSig(address(token), shopId, address(0), to, 1 ether, deadline, n, _sign(managerPk, h));
        assertEq(manager.balance, 1 ether); // payout = owner
    }

    function test_RefundExpired() public {
        _registerWithSig();
        _pay(100 ether);
        factory.checkpoint(address(token), shopId);
        ShopVaultFactory.RefundParams memory p = _refundParams(0, 1 ether, bytes32(uint256(1)));
        bytes memory s = _sign(managerPk, _refundHash(p));
        bytes memory c = _sign(adminPk, _refundHash(p));
        vm.warp(p.deadline + 1);
        vm.expectRevert(ShopVaultFactory.SignatureExpired.selector);
        factory.refundWithSig(p, s, c);
    }

    function test_InvalidSignatureBytesReverts() public {
        ShopVaultFactory.RegisterParams memory p = _params(shopId, ShopVaultFactory.ReceiveMode.SHOP, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 3));
        factory.registerShopWithSig(p, deadline, hex"010203");
    }
}
