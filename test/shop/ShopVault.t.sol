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

/// @dev Mimics PCECommunityToken: balances in raw units, display = raw x factor / 1e18, transfers take display amounts.
/// `arigatoBp` mints to the sender on each transfer (like ARIGATO creation).
contract MockCommunityToken {
    uint256 public factor = 1e18;
    uint256 public arigatoBp;
    mapping(address => uint256) public rawBalanceOf;

    function setFactor(uint256 f) external {
        factor = f;
    }

    function setArigatoBp(uint256 bp) external {
        arigatoBp = bp;
    }

    function rawBalanceToDisplayBalance(uint256 raw) public view returns (uint256) {
        return raw * factor / 1e18;
    }

    function displayBalanceToRawBalance(uint256 display) public view returns (uint256) {
        return display * 1e18 / factor;
    }

    function balanceOf(address account) external view returns (uint256) {
        return rawBalanceToDisplayBalance(rawBalanceOf[account]);
    }

    function mint(address to, uint256 display) external {
        rawBalanceOf[to] += displayBalanceToRawBalance(display);
    }

    function transfer(address to, uint256 display) external returns (bool) {
        uint256 raw = displayBalanceToRawBalance(display);
        require(rawBalanceOf[msg.sender] >= raw, "balance");
        rawBalanceOf[msg.sender] -= raw;
        rawBalanceOf[to] += raw;
        rawBalanceOf[msg.sender] += raw * arigatoBp / 10_000;
        return true;
    }
}

abstract contract ShopFixture is Test {
    ShopVaultFactory factory;
    MockCommunityToken token;
    address owner = makeAddr("owner");
    address relayer = makeAddr("relayer");
    address customer = makeAddr("customer");
    address payout = makeAddr("payout");
    address stranger = makeAddr("stranger");
    uint256 managerPk = 0xA1;
    uint256 adminPk = 0xA2;
    uint256 staffPk = 0xA3;
    uint256 strangerPk = 0xA4;
    address manager;
    address admin;
    address staff;
    bytes32 groupId = keccak256("group-1");
    bytes32 shopId = keccak256("shop-1");
    bytes32 terms = keccak256("monthly, paid in yen");
    // JST (+9h) with a 04:00 business-day cutoff -> months start on the 1st at 04:00 JST (= 19:00 UTC the day before)
    int32 constant OFFSET = 5 hours;
    uint256 constant T0 = 1_793_000_000; // 2026-10-26T08:53:20Z
    uint256 constant NOV_START = 1_793_473_200; // 2026-10-31T19:00:00Z = 2026-11-01 04:00 JST
    uint8 constant PERM_VIEW = 1;
    uint8 constant PERM_REFUND = 2;
    uint8 constant PERM_WITHDRAW = 4;
    uint8 constant PERM_MEMBERS = 16;
    uint8 constant PERM_ALL = 31;
    uint256 constant NO_BATCH = type(uint256).max;

    // read once so that signing helpers make no external call between vm.expectRevert and the call under test
    bytes32 domainSep;
    bytes32 REGISTER_SHOP_TYPEHASH;
    bytes32 SET_COMMUNITY_CONFIG_TYPEHASH;
    bytes32 SET_GROUP_PERMISSION_TYPEHASH;
    bytes32 SET_SHOP_PERMISSION_TYPEHASH;
    bytes32 SET_PAYOUT_TYPEHASH;
    bytes32 WITHDRAW_SHOP_SHARE_TYPEHASH;
    bytes32 WITHDRAW_COMMUNITY_SHARE_TYPEHASH;
    bytes32 REFUND_TYPEHASH;
    bytes32 RESCUE_TYPEHASH;

    function setUp() public virtual {
        manager = vm.addr(managerPk);
        admin = vm.addr(adminPk);
        staff = vm.addr(staffPk);
        vm.warp(T0);
        // deployed from the artifact so the test contracts stay under the code size limit
        factory = ShopVaultFactory(deployCode("ShopVaultFactory.sol:ShopVaultFactory", abi.encode(owner)));
        token = new MockCommunityToken();
        domainSep = factory.domainSeparator();
        REGISTER_SHOP_TYPEHASH = factory.REGISTER_SHOP_TYPEHASH();
        SET_COMMUNITY_CONFIG_TYPEHASH = factory.SET_COMMUNITY_CONFIG_TYPEHASH();
        SET_GROUP_PERMISSION_TYPEHASH = factory.SET_GROUP_PERMISSION_TYPEHASH();
        SET_SHOP_PERMISSION_TYPEHASH = factory.SET_SHOP_PERMISSION_TYPEHASH();
        SET_PAYOUT_TYPEHASH = factory.SET_PAYOUT_TYPEHASH();
        WITHDRAW_SHOP_SHARE_TYPEHASH = factory.WITHDRAW_SHOP_SHARE_TYPEHASH();
        WITHDRAW_COMMUNITY_SHARE_TYPEHASH = factory.WITHDRAW_COMMUNITY_SHARE_TYPEHASH();
        REFUND_TYPEHASH = factory.REFUND_TYPEHASH();
        RESCUE_TYPEHASH = factory.RESCUE_TYPEHASH();
        vm.startPrank(owner);
        factory.setCommunityAdmin(address(token), admin);
        factory.setRefundRelayer(relayer);
        vm.stopPrank();
        vm.prank(admin);
        factory.setCommunityConfig(address(token), true, 100_000 ether, terms);
    }

    function _params(
        bytes32 id,
        ShopVaultFactory.ReceiveMode mode,
        uint8 ratio,
        uint256 cap
    )
        internal
        view
        returns (ShopVaultFactory.RegisterParams memory)
    {
        return ShopVaultFactory.RegisterParams(
            address(token),
            id,
            groupId,
            mode,
            ratio,
            cap,
            OFFSET,
            mode == ShopVaultFactory.ReceiveMode.SHOP ? bytes32(0) : terms
        );
    }

    function _register(ShopVaultFactory.ReceiveMode mode, uint8 ratio, uint256 cap) internal {
        vm.prank(manager);
        factory.registerShop(_params(shopId, mode, ratio, cap));
    }

    function _vault() internal view returns (address) {
        return factory.predict(address(token), shopId);
    }

    function _pay(uint256 display) internal {
        token.mint(_vault(), display);
    }

    function _shares() internal view returns (uint256 shop, uint256 community) {
        (,, shop, community,,) = factory.balancesOf(address(token), shopId);
    }

    function _sign(uint256 pk, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _refundParams(
        uint256 batchId,
        uint256 amount,
        bytes32 nonce
    )
        internal
        view
        returns (ShopVaultFactory.RefundParams memory)
    {
        return ShopVaultFactory.RefundParams(
            address(token), shopId, batchId, customer, amount, block.timestamp + 1 hours, nonce
        );
    }

    function _refundHash(ShopVaultFactory.RefundParams memory p) internal view returns (bytes32) {
        return keccak256(abi.encode(REFUND_TYPEHASH, p.token, p.shopId, p.batchId, p.to, p.amount, p.deadline, p.nonce));
    }
}

contract ShopVaultRegistrationTest is ShopFixture {
    function test_PredictMatchesDeployed() public {
        _register(ShopVaultFactory.ReceiveMode.SHOP, 0, 0);
        address predicted = _vault();
        bytes32 s = keccak256(abi.encode(address(token), shopId));
        assertEq(predicted, vm.computeCreate2Address(s, factory.initCodeHash(), address(factory)));
        assertEq(predicted.code.length, 0);
        assertEq(factory.deployVault(address(token), shopId), predicted);
        assertEq(ShopVault(payable(predicted)).controller(), address(factory));
    }

    function test_VaultDirectCallReverts() public {
        address vault = factory.deployVault(address(token), shopId);
        vm.prank(manager);
        vm.expectRevert(ShopVault.NotController.selector);
        ShopVault(payable(vault)).withdrawNative(manager, 0);
        vm.expectRevert(ShopVault.AlreadyInitialized.selector);
        ShopVault(payable(vault)).initialize(address(token), shopId, stranger);
    }

    function test_FirstShopCreatesGroup_OwnerAddsShops() public {
        _register(ShopVaultFactory.ReceiveMode.SHOP, 0, 0);
        assertEq(factory.groupOwner(groupId), manager);
        assertEq(factory.shopOwner(address(token), shopId), manager);

        vm.prank(manager);
        vm.expectRevert(ShopVaultFactory.AlreadyRegistered.selector);
        factory.registerShop(_params(shopId, ShopVaultFactory.ReceiveMode.SHOP, 0, 0));

        bytes32 shop2 = keccak256("shop-2");
        vm.prank(stranger);
        vm.expectRevert(ShopVaultFactory.NotGroupOwner.selector);
        factory.registerShop(_params(shop2, ShopVaultFactory.ReceiveMode.SHOP, 0, 0));

        vm.prank(manager);
        factory.registerShop(_params(shop2, ShopVaultFactory.ReceiveMode.SHOP, 0, 0));
        assertEq(factory.getShop(address(token), shop2).groupId, groupId);

        // one person can own several groups
        ShopVaultFactory.RegisterParams memory p = _params(keccak256("shop-3"), ShopVaultFactory.ReceiveMode.SHOP, 0, 0);
        p.groupId = keccak256("group-2");
        vm.prank(manager);
        factory.registerShop(p);
        assertEq(factory.groupOwner(p.groupId), manager);
    }

    function test_ReceiveModeValidation() public {
        vm.startPrank(manager);
        // SPLIT cap above the community maximum
        vm.expectRevert(ShopVaultFactory.InvalidReceiveConfig.selector);
        factory.registerShop(_params(shopId, ShopVaultFactory.ReceiveMode.SPLIT, 50, 100_001 ether));
        // SPLIT needs a cap and ratio <= 100
        vm.expectRevert(ShopVaultFactory.InvalidReceiveConfig.selector);
        factory.registerShop(_params(shopId, ShopVaultFactory.ReceiveMode.SPLIT, 50, 0));
        vm.expectRevert(ShopVaultFactory.InvalidReceiveConfig.selector);
        factory.registerShop(_params(shopId, ShopVaultFactory.ReceiveMode.SPLIT, 101, 1 ether));
        // SHOP takes no ratio / cap
        vm.expectRevert(ShopVaultFactory.InvalidReceiveConfig.selector);
        factory.registerShop(_params(shopId, ShopVaultFactory.ReceiveMode.SHOP, 10, 0));
        // agreed terms must be the current ones
        ShopVaultFactory.RegisterParams memory p = _params(shopId, ShopVaultFactory.ReceiveMode.COMMUNITY, 100, 0);
        p.termsHash = keccak256("old terms");
        vm.expectRevert(ShopVaultFactory.TermsMismatch.selector);
        factory.registerShop(p);
        // period offset within +-1 day
        p = _params(shopId, ShopVaultFactory.ReceiveMode.SHOP, 0, 0);
        p.periodOffset = 1 days + 1;
        vm.expectRevert(ShopVaultFactory.InvalidReceiveConfig.selector);
        factory.registerShop(p);
        vm.stopPrank();
    }

    function test_CommunityConfigOnlyAdmin_DisallowKeepsExistingShops() public {
        vm.prank(stranger);
        vm.expectRevert(ShopVaultFactory.NotCommunityAdmin.selector);
        factory.setCommunityConfig(address(token), false, 0, bytes32(0));

        _register(ShopVaultFactory.ReceiveMode.SPLIT, 100, 50_000 ether);
        vm.prank(admin);
        factory.setCommunityConfig(address(token), false, 0, terms);

        // new SPLIT / COMMUNITY shops are no longer possible
        vm.prank(manager);
        vm.expectRevert(ShopVaultFactory.CommunityReceiveNotAllowed.selector);
        factory.registerShop(_params(keccak256("shop-2"), ShopVaultFactory.ReceiveMode.COMMUNITY, 100, 0));

        // the existing shop keeps splitting as registered
        _pay(60_000 ether);
        (uint256 shop, uint256 community) = _shares();
        assertEq(community, 50_000 ether);
        assertEq(shop, 10_000 ether);
        ShopVaultFactory.Shop memory s = factory.getShop(address(token), shopId);
        assertEq(uint8(s.mode), uint8(ShopVaultFactory.ReceiveMode.SPLIT));
        assertEq(s.cap, 50_000 ether);
    }

    function test_PeriodBoundaryFollowsBusinessDayCutoff() public view {
        // 2026-10-31T18:59:59Z = 11/1 03:59:59 JST -> still October's business month
        assertEq(factory.periodOf(OFFSET, NOV_START - 1), 2026 * 12 + 9);
        assertEq(factory.periodOf(OFFSET, NOV_START), 2026 * 12 + 10);
        assertEq(factory.periodStart(OFFSET, 2026 * 12 + 10), NOV_START);
        // year end and leap day
        assertEq(factory.periodOf(0, 1_798_761_600), 2027 * 12); // 2027-01-01T00:00:00Z
        assertEq(factory.periodOf(0, 1_835_395_200), 2028 * 12 + 1); // 2028-02-29T00:00:00Z
        assertEq(factory.periodStart(0, 2028 * 12 + 2), 1_835_481_600); // 2028-03-01T00:00:00Z
    }
}

contract ShopVaultSplitTest is ShopFixture {
    function setUp() public override {
        super.setUp();
        _register(ShopVaultFactory.ReceiveMode.SPLIT, 100, 50_000 ether);
    }

    function _checkpoint() internal returns (uint256) {
        return factory.checkpoint(address(token), shopId);
    }

    /// The example in the design deck: ratio 100%, cap 50,000 per month.
    function test_CapCrossingPaymentIsProrated() public {
        _pay(30_000 ether);
        assertEq(_checkpoint(), 0);
        _pay(30_000 ether);
        assertEq(_checkpoint(), 1);
        _pay(5000 ether);
        assertEq(_checkpoint(), 2);

        ShopVaultFactory.Batch memory b1 = factory.getBatch(address(token), shopId, 1);
        assertEq(b1.rawIn, 30_000 ether);
        assertEq(b1.communityRaw, 20_000 ether);
        assertEq(b1.communityDisplay, 20_000 ether);
        assertEq(factory.getBatch(address(token), shopId, 2).communityRaw, 0);
        assertEq(b1.accountedRawAfter, 60_000 ether);
        assertEq(factory.getBatch(address(token), shopId, 2).accountedRawAfter, 65_000 ether);

        (uint256 shop, uint256 community) = _shares();
        assertEq(community, 50_000 ether);
        assertEq(shop, 15_000 ether);
        assertEq(factory.getShop(address(token), shopId).periodCommunityDisplay, 50_000 ether);
    }

    function test_PlainTransfersWithoutCheckpointGiveSameTotals() public {
        _pay(30_000 ether);
        _pay(30_000 ether);
        _pay(5000 ether);
        (uint256 shop, uint256 community) = _shares();
        assertEq(community, 50_000 ether);
        assertEq(shop, 15_000 ether);
        assertEq(_checkpoint(), 0);
        assertEq(_checkpoint(), NO_BATCH); // nothing new
    }

    function test_RatioSplitsEachPayment() public {
        vm.prank(manager);
        factory.registerShop(_params(keccak256("half"), ShopVaultFactory.ReceiveMode.SPLIT, 50, 50_000 ether));
        token.mint(factory.predict(address(token), keccak256("half")), 10_000 ether);
        (,, uint256 shop, uint256 community,,) = factory.balancesOf(address(token), keccak256("half"));
        assertEq(shop, 5000 ether);
        assertEq(community, 5000 ether);
    }

    function test_CapResetsInNextPeriod() public {
        _pay(60_000 ether);
        _checkpoint();
        vm.warp(NOV_START - 1);
        _pay(1000 ether);
        _checkpoint();
        (uint256 shop, uint256 community) = _shares();
        assertEq(community, 50_000 ether);
        assertEq(shop, 11_000 ether);

        vm.warp(NOV_START);
        _pay(1000 ether);
        (,,,,, uint256 periodCommunity) = factory.balancesOf(address(token), shopId);
        assertEq(periodCommunity, 1000 ether);
        _checkpoint();
        (shop, community) = _shares();
        assertEq(community, 51_000 ether);
        assertEq(shop, 11_000 ether);
        assertEq(factory.getShop(address(token), shopId).period, 2026 * 12 + 10);
    }

    function test_DemurrageIsBorneByEachShare() public {
        _pay(60_000 ether);
        _checkpoint();
        token.setFactor(0.5e18); // display halves, raw does not
        (uint256 shop, uint256 community) = _shares();
        assertEq(community, 25_000 ether);
        assertEq(shop, 5000 ether);
        // the cap is counted in display units at the time of receipt: 50,000 already used this month
        _pay(1000 ether);
        (shop, community) = _shares();
        assertEq(community, 25_000 ether);
        assertEq(shop, 6000 ether);
    }

    function test_RefundChargesBothSharesAsOriginallySplit() public {
        _pay(30_000 ether);
        _checkpoint();
        _pay(30_000 ether); // batch 1: community 20,000 / shop 10,000
        _checkpoint();

        ShopVaultFactory.RefundParams memory p = _refundParams(1, 3000 ether, bytes32(uint256(1)));
        bytes memory shopSig = _sign(managerPk, _refundHash(p));
        bytes memory communitySig = _sign(adminPk, _refundHash(p));

        // both sides must sign
        vm.expectRevert();
        factory.refundWithSig(p, shopSig, "");
        vm.expectRevert(ShopVaultFactory.NotCommunityAdmin.selector);
        factory.refundWithSig(p, shopSig, _sign(strangerPk, _refundHash(p)));

        factory.refundWithSig(p, shopSig, communitySig);
        assertEq(token.balanceOf(customer), 3000 ether);
        (uint256 shop, uint256 community) = _shares();
        assertEq(community, 48_000 ether);
        assertEq(shop, 9000 ether);
        // same period: the community's room under the cap comes back
        assertEq(factory.getShop(address(token), shopId).periodCommunityDisplay, 48_000 ether);
        assertEq(factory.communityDisplayByPeriod(address(token), shopId, 2026 * 12 + 9), 48_000 ether);

        vm.expectRevert(ShopVaultFactory.NonceAlreadyUsed.selector);
        factory.refundWithSig(p, shopSig, communitySig);

        // cannot refund more than the batch received
        ShopVaultFactory.RefundParams memory big = _refundParams(1, 27_001 ether, bytes32(uint256(2)));
        vm.expectRevert(ShopVaultFactory.RefundExceedsBatch.selector);
        factory.refundWithSig(big, _sign(managerPk, _refundHash(big)), _sign(adminPk, _refundHash(big)));

        ShopVaultFactory.RefundParams memory none = _refundParams(9, 1 ether, bytes32(uint256(3)));
        vm.expectRevert(ShopVaultFactory.InvalidBatch.selector);
        factory.refundWithSig(none, _sign(managerPk, _refundHash(none)), _sign(adminPk, _refundHash(none)));
    }

    function test_RefundOfShopOnlyPortionNeedsNoCommunitySig() public {
        _pay(60_000 ether);
        _checkpoint();
        _pay(5000 ether); // batch 1: all shop (cap reached)
        _checkpoint();
        ShopVaultFactory.RefundParams memory p = _refundParams(1, 5000 ether, bytes32(uint256(1)));
        factory.refundWithSig(p, _sign(managerPk, _refundHash(p)), "");
        (uint256 shop, uint256 community) = _shares();
        assertEq(community, 50_000 ether);
        assertEq(shop, 10_000 ether);
    }

    function test_RefundInLaterPeriodDoesNotRestoreRoom() public {
        _pay(50_000 ether);
        _checkpoint();
        vm.warp(NOV_START);
        _pay(10_000 ether);
        _checkpoint(); // batch 1 in November: community 10,000
        ShopVaultFactory.RefundParams memory p = _refundParams(0, 10_000 ether, bytes32(uint256(1)));
        factory.refundWithSig(p, "", _sign(adminPk, _refundHash(p)));
        assertEq(factory.getShop(address(token), shopId).periodCommunityDisplay, 10_000 ether);
        // the base for October's consideration goes down by the refund; November's is unchanged
        assertEq(factory.communityDisplayByPeriod(address(token), shopId, 2026 * 12 + 9), 40_000 ether);
        assertEq(factory.communityDisplayByPeriod(address(token), shopId, 2026 * 12 + 10), 10_000 ether);
        (uint256 shop, uint256 community) = _shares();
        assertEq(community, 50_000 ether);
        assertEq(shop, 0);
    }

    function test_StaffRefundOnlyThroughRelayer() public {
        vm.prank(manager);
        factory.setShopPermission(address(token), shopId, staff, PERM_REFUND);
        _pay(60_000 ether);
        _checkpoint();
        _pay(1000 ether);
        _checkpoint();
        ShopVaultFactory.RefundParams memory p = _refundParams(1, 1000 ether, bytes32(uint256(1)));
        bytes memory sig = _sign(staffPk, _refundHash(p));
        // submitted by the staff themself (refund could go anywhere): rejected
        vm.prank(staff);
        vm.expectRevert(ShopVaultFactory.NotAuthorized.selector);
        factory.refundWithSig(p, sig, "");
        // a member without REFUND: rejected even through the relayer
        ShopVaultFactory.RefundParams memory q = _refundParams(1, 1000 ether, bytes32(uint256(2)));
        vm.prank(relayer);
        vm.expectRevert(ShopVaultFactory.NotAuthorized.selector);
        factory.refundWithSig(q, _sign(strangerPk, _refundHash(q)), "");
        // through the relayer (the server checked the payer)
        vm.prank(relayer);
        factory.refundWithSig(p, sig, "");
        assertEq(token.balanceOf(customer), 1000 ether);
    }

    function test_WithdrawEachShare() public {
        _pay(65_000 ether);
        // the shop cannot take the community's part
        vm.prank(manager);
        vm.expectRevert(ShopVaultFactory.InsufficientShare.selector);
        factory.withdrawShopShare(address(token), shopId, 15_001 ether);
        vm.prank(manager);
        factory.withdrawShopShare(address(token), shopId, 15_000 ether);
        assertEq(token.balanceOf(manager), 15_000 ether); // payout defaults to the group owner

        vm.prank(manager);
        vm.expectRevert(ShopVaultFactory.NotCommunityAdmin.selector);
        factory.withdrawCommunityShare(address(token), shopId, manager, 1 ether);
        vm.prank(admin);
        vm.expectRevert(ShopVaultFactory.InsufficientShare.selector);
        factory.withdrawCommunityShare(address(token), shopId, admin, 50_001 ether);
        vm.prank(admin);
        factory.withdrawCommunityShare(address(token), shopId, admin, 50_000 ether);
        assertEq(token.balanceOf(admin), 50_000 ether);
        assertEq(token.balanceOf(_vault()), 0);

        // later payments keep splitting after withdrawals (cap already used this month)
        _pay(1000 ether);
        (uint256 shop, uint256 community) = _shares();
        assertEq(shop, 1000 ether);
        assertEq(community, 0);
    }

    function test_ArigatoMintedOnSendGoesToTheSender() public {
        _pay(60_000 ether);
        token.setArigatoBp(100); // 1% of what the vault sends is minted back to it
        vm.prank(admin);
        factory.withdrawCommunityShare(address(token), shopId, admin, 50_000 ether);
        (uint256 shop, uint256 community) = _shares();
        assertEq(community, 500 ether);
        assertEq(shop, 10_000 ether);
        // not counted as a payment under the cap
        assertEq(factory.getShop(address(token), shopId).periodCommunityDisplay, 50_000 ether);
    }
}

contract ShopVaultModeTest is ShopFixture {
    function test_ShopMode_AllToShop_StaffWithdrawsOnlyToPayout() public {
        _register(ShopVaultFactory.ReceiveMode.SHOP, 0, 0);
        _pay(100 ether);
        (uint256 shop, uint256 community) = _shares();
        assertEq(shop, 100 ether);
        assertEq(community, 0);

        vm.prank(staff);
        vm.expectRevert(ShopVaultFactory.NotAuthorized.selector);
        factory.withdrawShopShare(address(token), shopId, 1 ether);

        vm.prank(manager);
        factory.setShopPermission(address(token), shopId, staff, PERM_WITHDRAW);
        vm.prank(staff);
        vm.expectRevert(ShopVaultFactory.NotGroupOwner.selector);
        factory.setPayout(address(token), shopId, staff);
        vm.prank(manager);
        factory.setPayout(address(token), shopId, payout);

        vm.prank(staff);
        factory.withdrawShopShare(address(token), shopId, 40 ether);
        assertEq(token.balanceOf(payout), 40 ether);
        assertEq(token.balanceOf(staff), 0);

        // the admin has no claim on a SHOP shop
        vm.prank(admin);
        vm.expectRevert(ShopVaultFactory.InsufficientShare.selector);
        factory.withdrawCommunityShare(address(token), shopId, admin, 1);

        // refund by the owner alone (no relayer needed)
        ShopVaultFactory.RefundParams memory p = _refundParams(NO_BATCH, 10 ether, bytes32(uint256(1)));
        factory.refundWithSig(p, _sign(managerPk, _refundHash(p)), "");
        assertEq(token.balanceOf(customer), 10 ether);
        (shop,) = _shares();
        assertEq(shop, 50 ether);
    }

    function test_CommunityMode_AllToCommunity_AdminRefunds() public {
        _register(ShopVaultFactory.ReceiveMode.COMMUNITY, 100, 0);
        _pay(100 ether);
        (uint256 shop, uint256 community) = _shares();
        assertEq(shop, 0);
        assertEq(community, 100 ether);

        ShopVaultFactory.RefundParams memory p = _refundParams(NO_BATCH, 30 ether, bytes32(uint256(1)));
        vm.expectRevert(ShopVaultFactory.NotCommunityAdmin.selector);
        factory.refundWithSig(p, _sign(managerPk, _refundHash(p)), "");
        factory.refundWithSig(p, "", _sign(adminPk, _refundHash(p)));
        assertEq(token.balanceOf(customer), 30 ether);

        vm.prank(manager);
        vm.expectRevert(ShopVaultFactory.InsufficientShare.selector);
        factory.withdrawShopShare(address(token), shopId, 1 ether);
        vm.prank(admin);
        factory.withdrawCommunityShare(address(token), shopId, admin, 70 ether);
        assertEq(token.balanceOf(admin), 70 ether);
    }

    function test_PaymentsBeforeRegistrationAreSplitToo() public {
        _pay(100 ether);
        _register(ShopVaultFactory.ReceiveMode.COMMUNITY, 100, 0);
        (, uint256 community) = _shares();
        assertEq(community, 100 ether);
    }

    function test_RescueOtherAssets() public {
        _register(ShopVaultFactory.ReceiveMode.SHOP, 0, 0);
        MockERC20 other = new MockERC20();
        other.mint(_vault(), 5);
        vm.deal(_vault(), 1 ether);
        vm.prank(manager);
        factory.setPayout(address(token), shopId, payout);
        vm.startPrank(manager);
        vm.expectRevert(ShopVaultFactory.UseShareWithdraw.selector);
        factory.rescue(address(token), shopId, address(token), manager, 1);
        factory.rescue(address(token), shopId, address(other), stranger, 5);
        factory.rescue(address(token), shopId, address(0), stranger, 1 ether);
        vm.stopPrank();
        // shop side always goes to the payout address
        assertEq(other.balanceOf(payout), 5);
        assertEq(payout.balance, 1 ether);
    }
}

contract ShopVaultPermissionTest is ShopFixture {
    bytes32 shop2 = keccak256("shop-2");

    function setUp() public override {
        super.setUp();
        _register(ShopVaultFactory.ReceiveMode.SHOP, 0, 0);
        vm.prank(manager);
        factory.registerShop(_params(shop2, ShopVaultFactory.ReceiveMode.SHOP, 0, 0));
    }

    function test_GroupLevelAppliesToAllShops_ShopLevelToOne() public {
        uint8 w = PERM_WITHDRAW;
        vm.prank(manager);
        factory.setShopPermission(address(token), shopId, staff, w);
        assertTrue(factory.hasPermission(address(token), shopId, staff, w));
        assertFalse(factory.hasPermission(address(token), shop2, staff, w));

        vm.prank(manager);
        factory.setGroupPermission(groupId, stranger, w | PERM_VIEW);
        assertTrue(factory.hasPermission(address(token), shopId, stranger, w));
        assertTrue(factory.hasPermission(address(token), shop2, stranger, w));
        assertEq(factory.permissionsOf(address(token), shop2, manager), PERM_ALL);
    }

    function test_MemberManagerCannotEscalate() public {
        uint8 members = PERM_MEMBERS;
        uint8 view_ = PERM_VIEW;
        uint8 w = PERM_WITHDRAW;
        vm.prank(manager);
        factory.setShopPermission(address(token), shopId, staff, members | view_);

        // can grant what it holds
        vm.prank(staff);
        factory.setShopPermission(address(token), shopId, stranger, view_);
        // cannot grant WITHDRAW it does not hold, nor change the owner, nor act on another shop
        vm.prank(staff);
        vm.expectRevert(ShopVaultFactory.NotAuthorized.selector);
        factory.setShopPermission(address(token), shopId, stranger, view_ | w);
        vm.prank(staff);
        vm.expectRevert(ShopVaultFactory.InvalidPermissions.selector);
        factory.setShopPermission(address(token), shopId, manager, 0);
        vm.prank(staff);
        vm.expectRevert(ShopVaultFactory.NotAuthorized.selector);
        factory.setShopPermission(address(token), shop2, stranger, view_);
        // shop-level MEMBERS does not reach the group level
        vm.prank(staff);
        vm.expectRevert(ShopVaultFactory.NotAuthorized.selector);
        factory.setGroupPermission(groupId, stranger, view_);

        // cannot revoke someone holding more than itself
        vm.prank(manager);
        factory.setShopPermission(address(token), shopId, stranger, w);
        vm.prank(staff);
        vm.expectRevert(ShopVaultFactory.NotAuthorized.selector);
        factory.setShopPermission(address(token), shopId, stranger, 0);
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
