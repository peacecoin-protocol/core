// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { PCECommunityToken } from "src/PCECommunityToken.sol";
import { PCEToken } from "src/PCEToken.sol";
import { ExchangeAllowMethod } from "src/lib/Enum.sol";
import { ShopVaultFactory } from "src/shop/ShopVaultFactory.sol";

contract ShopTestBeacon {
    address public implementation;

    constructor(address impl) {
        implementation = impl;
    }
}

/// @notice ShopVaultFactory against the real PCECommunityToken (raw balances, daily demurrage, ARIGATO creation).
contract ShopVaultCommunityTokenTest is Test {
    PCEToken pce;
    PCECommunityToken ct;
    ShopVaultFactory factory;
    address customer = makeAddr("customer");
    uint256 managerPk = 0xB1;
    uint256 adminPk = 0xB2;
    address manager = vm.addr(managerPk);
    address admin = vm.addr(adminPk);
    bytes32 shopId = keccak256("shop");
    bytes32 groupId = keccak256("group");

    function setUp() public {
        vm.warp(1_791_000_000); // 2026-10-03, so that ten days later is still the same month
        pce = PCEToken(deployCode("PCEToken.sol:PCEToken"));
        pce.initialize();
        // values set by V1's initialize on the real deployment (see PCE.t.sol)
        vm.store(address(pce), bytes32(uint256(3)), bytes32(uint256(396_140_812_571_321_687_967_719_751_680)));
        vm.store(address(pce), bytes32(uint256(4)), bytes32(uint256(200_000)));
        vm.store(address(pce), bytes32(uint256(5)), bytes32(uint256(50_000_000_000)));
        vm.store(address(pce), bytes32(uint256(6)), bytes32(uint256(300)));
        vm.store(address(pce), bytes32(uint256(7)), bytes32(uint256(300)));
        pce.setCommunityTokenAddress(address(new ShopTestBeacon(deployCode("PCECommunityToken.sol:PCECommunityToken"))));
        pce.mint(address(this), 10_000 ether);
        address[] memory none = new address[](0);
        pce.createToken(
            "Shop Test",
            "SHT",
            1000 ether,
            1 ether,
            1,
            9800,
            1000,
            500,
            1000,
            100,
            ExchangeAllowMethod.All,
            ExchangeAllowMethod.All,
            none,
            none
        );
        ct = PCECommunityToken(pce.getTokens()[0]);
        pce.swapToLocalToken(address(ct), 1000 ether);
        ct.transfer(customer, ct.balanceOf(address(this)));

        factory = ShopVaultFactory(deployCode("ShopVaultFactory.sol:ShopVaultFactory", abi.encode(address(this))));
        factory.setCommunityAdmin(address(ct), admin);
        vm.prank(admin);
        factory.setCommunityConfig(address(ct), true, 0, bytes32(0));
        vm.prank(manager);
        factory.registerShop(
            ShopVaultFactory.RegisterParams(
                address(ct), shopId, groupId, ShopVaultFactory.ReceiveMode.SPLIT, 100, 50 ether, 5 hours, bytes32(0)
            )
        );
    }

    function _pay(uint256 display) internal {
        address vault = factory.predict(address(ct), shopId);
        vm.prank(customer);
        ct.transfer(vault, display);
    }

    function _approx(uint256 a, uint256 b) internal pure {
        assertApproxEqAbs(a, b, 1e6, "display amounts differ by more than dust");
    }

    function test_SplitWithDemurrage_WithdrawEverything() public {
        address vault = factory.predict(address(ct), shopId);
        _pay(30 ether);
        factory.checkpoint(address(ct), shopId);
        _pay(30 ether); // crosses the cap: 20 to the community, 10 to the shop
        _pay(5 ether); // lazily split with the previous one (no checkpoint in between)

        (,, uint256 shopDisplay, uint256 communityDisplay,,) = factory.balancesOf(address(ct), shopId);
        _approx(communityDisplay, 50 ether);
        _approx(shopDisplay, 15 ether);
        _approx(shopDisplay + communityDisplay, ct.balanceOf(vault));

        factory.checkpoint(address(ct), shopId);
        // ten days of 2% daily demurrage: both shares decay by the same factor, in raw units nothing changes
        vm.warp(block.timestamp + 10 days);
        uint256 vaultDisplay = ct.balanceOf(vault);
        (uint256 shopRaw, uint256 communityRaw, uint256 shopD, uint256 commD,,) =
            factory.balancesOf(address(ct), shopId);
        assertLt(vaultDisplay, 65 ether * 83 / 100);
        _approx(shopD + commD, vaultDisplay);
        assertApproxEqRel(commD * 15, shopD * 50, 1e9);

        // refund 3 from batch 1 (the 30 + 5 batch: community 20 / shop 15 of 35)
        ShopVaultFactory.RefundParams memory p = ShopVaultFactory.RefundParams(
            address(ct), shopId, 1, customer, 3 ether, block.timestamp + 1 hours, bytes32(uint256(1))
        );
        // the owner signs the shop part, the admin the community part
        bytes32 h = keccak256(
            abi.encode(factory.REFUND_TYPEHASH(), p.token, p.shopId, p.batchId, p.to, p.amount, p.deadline, p.nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", factory.domainSeparator(), h));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(managerPk, digest);
        bytes memory shopSig = abi.encodePacked(r, s, v);
        (v, r, s) = vm.sign(adminPk, digest);
        uint256 before = ct.balanceOf(customer);
        factory.refundWithSig(p, shopSig, abi.encodePacked(r, s, v));
        _approx(ct.balanceOf(customer) - before, 3 ether);
        (uint256 shopRaw2, uint256 communityRaw2,,,,) = factory.balancesOf(address(ct), shopId);
        uint256 refundRaw = ct.displayBalanceToRawBalance(3 ether);
        // charged 20/35 to the community and 15/35 to the shop (ARIGATO minted on the send is credited back)
        uint256 communityDelta = communityRaw - communityRaw2;
        uint256 shopDelta = shopRaw - shopRaw2;
        assertApproxEqRel(communityDelta * 15, shopDelta * 20, 1e9);
        assertLe(communityDelta + shopDelta, refundRaw);

        // withdraw everything each side holds
        (,, shopD, commD,,) = factory.balancesOf(address(ct), shopId);
        vm.prank(manager);
        factory.withdrawShopShare(address(ct), shopId, shopD);
        vm.prank(admin);
        factory.withdrawCommunityShare(address(ct), shopId, admin, commD);
        (,, shopD, commD,,) = factory.balancesOf(address(ct), shopId);
        // what is left is ARIGATO minted to the vault by these sends (plus rounding dust), credited to the senders
        _approx(shopD + commD, ct.balanceOf(vault));
        assertLt(ct.balanceOf(vault), 5 ether);
    }
}
