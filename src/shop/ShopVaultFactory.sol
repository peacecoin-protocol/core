// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ShopVault } from "./ShopVault.sol";

/// @notice The parts of PCECommunityToken the factory reads. Balances are held in raw units internally;
/// display = raw x factor (demurrage, rebase). Raw amounts do not decay, so the accounting below is kept in raw units.
interface ICommunityToken {
    function balanceOf(address account) external view returns (uint256);
    function rawBalanceToDisplayBalance(uint256 rawBalance) external view returns (uint256);
    function displayBalanceToRawBalance(uint256 displayBalance) external view returns (uint256);
}

/// @notice Shop registry, receive-method accounting and withdraw policy for per-shop vaults.
///
/// Vault address = CREATE2(factory, keccak256(abi.encode(token, shopId)), keccak256(cloneInitCode(implementation))).
/// Payments are plain ERC20 transfers to the vault (no hook). The factory splits what the vault has received between
/// the shop and the community lazily, at checkpoints:
///
///   totalReceivedRaw = rawBalance(vault) + shopOutRaw + communityOutRaw
///   d                = totalReceivedRaw - accountedRaw              (receipts not yet split)
///   SHOP:       community += 0
///   COMMUNITY:  community += d
///   SPLIT:      communityDisplay = min(display(d) x ratio / 100, cap - periodCommunityDisplay)
///               community += d x communityDisplay / display(d)      (the payment that crosses the cap is prorated)
///   shop share = accountedRaw - communityAccruedRaw - shopOutRaw
///   community share = communityAccruedRaw - communityOutRaw
///
/// Each checkpoint that splits new receipts is stored as a batch so that a refund can be charged to both shares in
/// the proportion its original payment was split. Demurrage is borne by whoever holds each share (raw units).
contract ShopVaultFactory is Ownable, EIP712 {
    enum ReceiveMode {
        SHOP,
        COMMUNITY,
        SPLIT
    }

    uint8 public constant PERM_VIEW = 1;
    uint8 public constant PERM_REFUND = 2;
    uint8 public constant PERM_WITHDRAW = 4;
    uint8 public constant PERM_EDIT = 8;
    uint8 public constant PERM_MEMBERS = 16;
    uint8 public constant PERM_ALL = 31;

    /// @notice batchId to pass to refund for SHOP / COMMUNITY shops (the split does not depend on the payment).
    uint256 public constant NO_BATCH = type(uint256).max;
    int32 public constant MAX_PERIOD_OFFSET = 1 days;

    struct CommunityConfig {
        bool allowCommunityReceive;
        /// @dev Maximum cap per period a SPLIT shop may choose (display units). 0 = no maximum.
        uint256 maxCap;
        /// @dev keccak256 of the off-chain payment terms the shop agrees to at registration.
        bytes32 termsHash;
    }

    struct Shop {
        bytes32 groupId;
        ReceiveMode mode;
        uint8 ratioPct;
        /// @dev seconds added to block.timestamp before taking the calendar month (e.g. JST 9h - cutoff 4h = 5h).
        int32 periodOffset;
        /// @dev community cap per period, display units (SPLIT only).
        uint256 cap;
        /// @dev where the shop share is withdrawn to; address(0) = the group owner.
        address payout;
        uint256 accountedRaw;
        uint256 communityAccruedRaw;
        uint256 communityOutRaw;
        uint256 shopOutRaw;
        uint256 period;
        uint256 periodCommunityDisplay;
        uint256 batchCount;
    }

    struct Batch {
        uint256 period;
        uint256 timestamp;
        uint256 rawIn;
        uint256 communityRaw;
        uint256 communityDisplay;
        uint256 refundedRaw;
        /// @dev cumulative raw received up to the end of this batch (accountedRaw after it). A payment whose cumulative
        /// receipts (sum of PCETransfer rawAmount into the vault, in order) fall in (previous, this] is in this batch.
        uint256 accountedRawAfter;
    }

    struct RegisterParams {
        address token;
        bytes32 shopId;
        bytes32 groupId;
        ReceiveMode mode;
        uint8 ratioPct;
        uint256 cap;
        int32 periodOffset;
        bytes32 termsHash;
    }

    struct RefundParams {
        address token;
        bytes32 shopId;
        uint256 batchId;
        address to;
        uint256 amount;
        uint256 deadline;
        bytes32 nonce;
    }

    address public immutable implementation;
    /// @notice The server relayer. A refund signed by a member other than the group owner is accepted only when this
    /// address submits it (the server checks the refund goes back to the payer). It cannot move funds by itself.
    address public refundRelayer;

    /// @dev Simplified model of the community admin; the real version should read it from the community token.
    mapping(address token => address) public communityAdmin;
    mapping(address token => CommunityConfig) public communityConfig;
    mapping(bytes32 groupId => address) public groupOwner;
    mapping(bytes32 groupId => mapping(address account => uint8)) public groupPermission;
    mapping(address token => mapping(bytes32 shopId => mapping(address account => uint8))) public shopPermission;
    mapping(address token => mapping(bytes32 shopId => Shop)) internal _shops;
    mapping(address token => mapping(bytes32 shopId => mapping(uint256 batchId => Batch))) internal _batches;
    /// @notice Community share received per period (display units at receipt, net of refunds charged to it). The base
    /// amount for the consideration the community pays the shop for that period.
    mapping(address token => mapping(bytes32 shopId => mapping(uint256 period => uint256))) public
        communityDisplayByPeriod;
    mapping(address signer => mapping(bytes32 nonce => bool)) public nonceUsed;
    mapping(bytes32 nonce => bool) public refundNonceUsed;

    bytes32 public constant REGISTER_SHOP_TYPEHASH = keccak256(
        "RegisterShop(address token,bytes32 shopId,bytes32 groupId,uint8 mode,uint8 ratioPct,uint256 cap,"
        "int32 periodOffset,bytes32 termsHash,uint256 deadline)"
    );
    bytes32 public constant SET_COMMUNITY_CONFIG_TYPEHASH = keccak256(
        "SetCommunityConfig(address token,bool allowCommunityReceive,uint256 maxCap,bytes32 termsHash,"
        "uint256 deadline,bytes32 nonce)"
    );
    bytes32 public constant SET_GROUP_PERMISSION_TYPEHASH = keccak256(
        "SetGroupPermission(bytes32 groupId,address account,uint8 permissions,uint256 deadline,bytes32 nonce)"
    );
    bytes32 public constant SET_SHOP_PERMISSION_TYPEHASH = keccak256(
        "SetShopPermission(address token,bytes32 shopId,address account,uint8 permissions,uint256 deadline,"
        "bytes32 nonce)"
    );
    bytes32 public constant SET_PAYOUT_TYPEHASH =
        keccak256("SetPayout(address token,bytes32 shopId,address payout,uint256 deadline,bytes32 nonce)");
    bytes32 public constant WITHDRAW_SHOP_SHARE_TYPEHASH =
        keccak256("WithdrawShopShare(address token,bytes32 shopId,uint256 amount,uint256 deadline,bytes32 nonce)");
    bytes32 public constant WITHDRAW_COMMUNITY_SHARE_TYPEHASH = keccak256(
        "WithdrawCommunityShare(address token,bytes32 shopId,address to,uint256 amount,uint256 deadline,bytes32 nonce)"
    );
    bytes32 public constant REFUND_TYPEHASH = keccak256(
        "Refund(address token,bytes32 shopId,uint256 batchId,address to,uint256 amount,uint256 deadline,bytes32 nonce)"
    );
    bytes32 public constant RESCUE_TYPEHASH = keccak256(
        "Rescue(address token,bytes32 shopId,address asset,address to,uint256 amount,uint256 deadline,bytes32 nonce)"
    );

    error NotCommunityAdmin();
    error NotGroupOwner();
    error NotRegistered();
    error AlreadyRegistered();
    error NotAuthorized();
    error SignatureExpired();
    error NonceAlreadyUsed();
    error CommunityReceiveNotAllowed();
    error InvalidReceiveConfig();
    error TermsMismatch();
    error InsufficientShare();
    error InvalidBatch();
    error RefundExceedsBatch();
    error UseShareWithdraw();
    error InvalidPermissions();

    event CommunityAdminSet(address indexed token, address admin);
    event RefundRelayerSet(address relayer);
    event CommunityConfigSet(address indexed token, bool allowCommunityReceive, uint256 maxCap, bytes32 termsHash);
    event GroupCreated(bytes32 indexed groupId, address owner);
    event ShopRegistered(
        address indexed token,
        bytes32 indexed shopId,
        bytes32 indexed groupId,
        ReceiveMode mode,
        uint8 ratioPct,
        uint256 cap,
        int32 periodOffset,
        address vault
    );
    event GroupPermissionSet(bytes32 indexed groupId, address indexed account, uint8 permissions);
    event ShopPermissionSet(address indexed token, bytes32 indexed shopId, address indexed account, uint8 permissions);
    event PayoutSet(address indexed token, bytes32 indexed shopId, address payout);
    event Checkpointed(
        address indexed token,
        bytes32 indexed shopId,
        uint256 indexed batchId,
        uint256 period,
        uint256 rawIn,
        uint256 communityRaw,
        uint256 displayIn,
        uint256 communityDisplay
    );
    event ShopShareWithdrawn(address indexed token, bytes32 indexed shopId, address to, uint256 amount, uint256 raw);
    event CommunityShareWithdrawn(
        address indexed token, bytes32 indexed shopId, address to, uint256 amount, uint256 raw
    );
    event Refunded(
        address indexed token,
        bytes32 indexed shopId,
        uint256 indexed batchId,
        address to,
        uint256 amount,
        uint256 shopRaw,
        uint256 communityRaw,
        bytes32 nonce
    );
    event Rescued(address indexed token, bytes32 indexed shopId, address asset, address to, uint256 amount);
    event VaultDeployed(address indexed token, bytes32 indexed shopId, address vault);

    constructor(address owner_) Ownable(owner_) EIP712("ShopVaultFactory", "2") {
        implementation = address(new ShopVault());
    }

    // ---------------------------------------------------------------------
    // Addresses
    // ---------------------------------------------------------------------

    function salt(address token, bytes32 shopId) public pure returns (bytes32) {
        return keccak256(abi.encode(token, shopId));
    }

    function predict(address token, bytes32 shopId) public view returns (address) {
        return Clones.predictDeterministicAddress(implementation, salt(token, shopId), address(this));
    }

    /// @notice keccak256 of the clone init code; constant per factory deployment (used by the web app).
    function initCodeHash() external view returns (bytes32 h) {
        bytes memory code = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3"
        );
        h = keccak256(code);
    }

    function deployVault(address token, bytes32 shopId) public returns (address vault) {
        vault = predict(token, shopId);
        if (vault.code.length == 0) {
            Clones.cloneDeterministic(implementation, salt(token, shopId));
            ShopVault(payable(vault)).initialize(token, shopId, address(this));
            emit VaultDeployed(token, shopId, vault);
        }
    }

    // ---------------------------------------------------------------------
    // Owner / community admin
    // ---------------------------------------------------------------------

    function setCommunityAdmin(address token, address admin) external onlyOwner {
        communityAdmin[token] = admin;
        emit CommunityAdminSet(token, admin);
    }

    function setRefundRelayer(address relayer) external onlyOwner {
        refundRelayer = relayer;
        emit RefundRelayerSet(relayer);
    }

    function setCommunityConfig(address token, bool allow, uint256 maxCap, bytes32 termsHash) external {
        _setCommunityConfig(msg.sender, token, allow, maxCap, termsHash);
    }

    /// @dev Applies to shops registered afterwards. Existing shops keep the receive method they registered with.
    function _setCommunityConfig(
        address sender,
        address token,
        bool allow,
        uint256 maxCap,
        bytes32 termsHash
    )
        internal
    {
        if (sender == address(0) || sender != communityAdmin[token]) revert NotCommunityAdmin();
        communityConfig[token] = CommunityConfig(allow, maxCap, termsHash);
        emit CommunityConfigSet(token, allow, maxCap, termsHash);
    }

    // ---------------------------------------------------------------------
    // Shops, groups, permissions
    // ---------------------------------------------------------------------

    function getShop(address token, bytes32 shopId) external view returns (Shop memory) {
        return _shops[token][shopId];
    }

    function getBatch(address token, bytes32 shopId, uint256 batchId) external view returns (Batch memory) {
        return _batches[token][shopId][batchId];
    }

    /// @notice Self-registration, no approval. The first shop of a group creates the group with the signer as owner;
    /// later shops can be added to the group by its owner. The receive method is fixed at registration.
    function registerShop(RegisterParams calldata p) external {
        _registerShop(msg.sender, p);
    }

    function _registerShop(address sender, RegisterParams calldata p) internal {
        Shop storage s = _shops[p.token][p.shopId];
        if (s.groupId != bytes32(0)) revert AlreadyRegistered();
        if (p.groupId == bytes32(0) || sender == address(0)) revert InvalidReceiveConfig();
        address owner_ = groupOwner[p.groupId];
        if (owner_ == address(0)) {
            groupOwner[p.groupId] = sender;
            emit GroupCreated(p.groupId, sender);
        } else if (owner_ != sender) {
            revert NotGroupOwner();
        }
        if (p.periodOffset > MAX_PERIOD_OFFSET || p.periodOffset < -MAX_PERIOD_OFFSET) revert InvalidReceiveConfig();

        uint8 ratio;
        uint256 cap;
        if (p.mode == ReceiveMode.SHOP) {
            if (p.ratioPct != 0 || p.cap != 0) revert InvalidReceiveConfig();
        } else {
            CommunityConfig storage c = communityConfig[p.token];
            if (!c.allowCommunityReceive) revert CommunityReceiveNotAllowed();
            if (p.termsHash != c.termsHash) revert TermsMismatch();
            if (p.mode == ReceiveMode.COMMUNITY) {
                if (p.cap != 0 || (p.ratioPct != 0 && p.ratioPct != 100)) revert InvalidReceiveConfig();
                ratio = 100;
            } else {
                if (p.ratioPct > 100 || p.cap == 0 || (c.maxCap != 0 && p.cap > c.maxCap)) {
                    revert InvalidReceiveConfig();
                }
                ratio = p.ratioPct;
                cap = p.cap;
            }
        }
        s.groupId = p.groupId;
        s.mode = p.mode;
        s.ratioPct = ratio;
        s.cap = cap;
        s.periodOffset = p.periodOffset;
        s.period = periodOf(p.periodOffset, block.timestamp);
        // Payments that reached the address before registration are split at the first checkpoint like any other.
        emit ShopRegistered(
            p.token, p.shopId, p.groupId, p.mode, ratio, cap, p.periodOffset, predict(p.token, p.shopId)
        );
    }

    function _registered(address token, bytes32 shopId) internal view returns (Shop storage s) {
        s = _shops[token][shopId];
        if (s.groupId == bytes32(0)) revert NotRegistered();
    }

    function shopOwner(address token, bytes32 shopId) public view returns (address) {
        return groupOwner[_shops[token][shopId].groupId];
    }

    /// @notice Effective permissions of `account` for a shop: group owner = all; otherwise group-level | shop-level.
    function permissionsOf(address token, bytes32 shopId, address account) public view returns (uint8) {
        bytes32 g = _shops[token][shopId].groupId;
        if (g == bytes32(0) || account == address(0)) return 0;
        if (account == groupOwner[g]) return PERM_ALL;
        return groupPermission[g][account] | shopPermission[token][shopId][account];
    }

    function hasPermission(address token, bytes32 shopId, address account, uint8 perm) public view returns (bool) {
        return perm != 0 && permissionsOf(token, shopId, account) & perm == perm;
    }

    function setGroupPermission(bytes32 groupId, address account, uint8 permissions) external {
        _setGroupPermission(msg.sender, groupId, account, permissions);
    }

    /// @dev The owner grants anything. A member with MEMBERS at group level may grant / revoke only permissions it
    /// holds itself, and cannot change the owner.
    function _setGroupPermission(address sender, bytes32 groupId, address account, uint8 permissions) internal {
        address owner_ = groupOwner[groupId];
        if (owner_ == address(0)) revert NotRegistered();
        if (permissions > PERM_ALL || account == address(0) || account == owner_) revert InvalidPermissions();
        uint8 mine = sender == owner_ ? PERM_ALL : groupPermission[groupId][sender];
        if (mine & PERM_MEMBERS == 0) revert NotAuthorized();
        uint8 current = groupPermission[groupId][account];
        if ((permissions | current) & ~mine != 0) revert NotAuthorized();
        groupPermission[groupId][account] = permissions;
        emit GroupPermissionSet(groupId, account, permissions);
    }

    function setShopPermission(address token, bytes32 shopId, address account, uint8 permissions) external {
        _setShopPermission(msg.sender, token, shopId, account, permissions);
    }

    function _setShopPermission(
        address sender,
        address token,
        bytes32 shopId,
        address account,
        uint8 permissions
    )
        internal
    {
        Shop storage s = _registered(token, shopId);
        if (permissions > PERM_ALL || account == address(0) || account == groupOwner[s.groupId]) {
            revert InvalidPermissions();
        }
        uint8 mine = permissionsOf(token, shopId, sender);
        if (mine & PERM_MEMBERS == 0) revert NotAuthorized();
        uint8 current = shopPermission[token][shopId][account];
        if ((permissions | current) & ~mine != 0) revert NotAuthorized();
        shopPermission[token][shopId][account] = permissions;
        emit ShopPermissionSet(token, shopId, account, permissions);
    }

    function setPayout(address token, bytes32 shopId, address payout) external {
        _setPayout(msg.sender, token, shopId, payout);
    }

    /// @dev Only the group owner chooses where the shop share goes, so staff with WITHDRAW cannot redirect it.
    function _setPayout(address sender, address token, bytes32 shopId, address payout) internal {
        Shop storage s = _registered(token, shopId);
        if (sender != groupOwner[s.groupId]) revert NotGroupOwner();
        s.payout = payout;
        emit PayoutSet(token, shopId, payout);
    }

    function payoutOf(address token, bytes32 shopId) public view returns (address) {
        Shop storage s = _shops[token][shopId];
        return s.payout != address(0) ? s.payout : groupOwner[s.groupId];
    }

    // ---------------------------------------------------------------------
    // Periods (calendar months shifted by periodOffset; boundaries are UTC timestamps)
    // ---------------------------------------------------------------------

    /// @notice Calendar month index (year * 12 + month - 1) of `timestamp + offset`.
    function periodOf(int32 offset, uint256 timestamp) public pure returns (uint256) {
        int256 t = int256(timestamp) + offset;
        if (t < 0) t = 0;
        (uint256 y, uint256 m) = _yearMonth(uint256(t) / 1 days);
        return y * 12 + (m - 1);
    }

    /// @notice UTC timestamp at which `period` starts for a shop with `offset`.
    function periodStart(int32 offset, uint256 period) public pure returns (uint256) {
        uint256 y = period / 12;
        uint256 m = period % 12 + 1;
        int256 t = int256(_daysFromCivil(y, m, 1) * 1 days) - offset;
        return t < 0 ? 0 : uint256(t);
    }

    /// @dev Howard Hinnant's civil_from_days (days since 1970-01-01, non-negative).
    function _yearMonth(uint256 day) internal pure returns (uint256 y, uint256 m) {
        uint256 z = day + 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        m = mp < 10 ? mp + 3 : mp - 9;
        y = yoe + era * 400 + (m <= 2 ? 1 : 0);
    }

    function _daysFromCivil(uint256 y, uint256 m, uint256 d) internal pure returns (uint256) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146_097 + doe - 719_468;
    }

    // ---------------------------------------------------------------------
    // Accounting
    // ---------------------------------------------------------------------

    /// @dev PCECommunityToken does not expose the raw balance; display -> raw rounds down, so this never exceeds the
    /// true raw balance (the gap is dust and stays in the vault).
    function _rawBalance(address token, address vault) internal view returns (uint256) {
        ICommunityToken ct = ICommunityToken(token);
        return ct.displayBalanceToRawBalance(ct.balanceOf(vault));
    }

    function _totalReceived(address token, bytes32 shopId, Shop storage s) internal view returns (uint256) {
        return _rawBalance(token, predict(token, shopId)) + s.shopOutRaw + s.communityOutRaw;
    }

    function _splitNew(
        address token,
        Shop storage s,
        uint256 d,
        uint256 periodCommunity
    )
        internal
        view
        returns (uint256 communityRaw, uint256 displayIn, uint256 communityDisplay)
    {
        displayIn = ICommunityToken(token).rawBalanceToDisplayBalance(d);
        if (s.mode == ReceiveMode.COMMUNITY) {
            return (d, displayIn, displayIn);
        }
        if (s.mode == ReceiveMode.SHOP) {
            return (0, displayIn, 0);
        }
        uint256 want = Math.mulDiv(displayIn, s.ratioPct, 100);
        uint256 room = s.cap > periodCommunity ? s.cap - periodCommunity : 0;
        communityDisplay = want < room ? want : room;
        // displayIn == 0 only for dust below one display unit; it stays with the shop.
        communityRaw = displayIn == 0 ? 0 : Math.mulDiv(d, communityDisplay, displayIn);
    }

    /// @notice Splits receipts that arrived since the last checkpoint. Anyone may call it (the relayer does so
    /// shortly after each payment); every withdraw / refund calls it first. Receipts are counted in the period in which
    /// they are checkpointed.
    function checkpoint(address token, bytes32 shopId) external returns (uint256 batchId) {
        return _checkpoint(token, shopId, _registered(token, shopId));
    }

    function _checkpoint(address token, bytes32 shopId, Shop storage s) internal returns (uint256 batchId) {
        uint256 period = periodOf(s.periodOffset, block.timestamp);
        if (s.period != period) {
            s.period = period;
            s.periodCommunityDisplay = 0;
        }
        uint256 total = _totalReceived(token, shopId, s);
        if (total <= s.accountedRaw) return NO_BATCH;
        uint256 d = total - s.accountedRaw;
        (uint256 communityRaw, uint256 displayIn, uint256 communityDisplay) =
            _splitNew(token, s, d, s.periodCommunityDisplay);
        s.accountedRaw = total;
        s.communityAccruedRaw += communityRaw;
        s.periodCommunityDisplay += communityDisplay;
        communityDisplayByPeriod[token][shopId][period] += communityDisplay;
        batchId = s.batchCount++;
        _batches[token][shopId][batchId] = Batch(period, block.timestamp, d, communityRaw, communityDisplay, 0, total);
        emit Checkpointed(token, shopId, batchId, period, d, communityRaw, displayIn, communityDisplay);
    }

    /// @notice Balances as if a checkpoint ran now (raw and display units).
    function balancesOf(
        address token,
        bytes32 shopId
    )
        external
        view
        returns (
            uint256 shopRaw,
            uint256 communityRaw,
            uint256 shopDisplay,
            uint256 communityDisplay,
            uint256 unaccountedRaw,
            uint256 periodCommunityDisplay
        )
    {
        Shop storage s = _shops[token][shopId];
        if (s.groupId == bytes32(0)) return (0, 0, 0, 0, 0, 0);
        uint256 period = periodOf(s.periodOffset, block.timestamp);
        periodCommunityDisplay = s.period == period ? s.periodCommunityDisplay : 0;
        uint256 total = _totalReceived(token, shopId, s);
        uint256 accrued = s.communityAccruedRaw;
        uint256 accounted = s.accountedRaw;
        if (total > accounted) {
            unaccountedRaw = total - accounted;
            (uint256 c,, uint256 cd) = _splitNew(token, s, unaccountedRaw, periodCommunityDisplay);
            accrued += c;
            periodCommunityDisplay += cd;
            accounted = total;
        }
        communityRaw = accrued - s.communityOutRaw;
        shopRaw = accounted - accrued - s.shopOutRaw;
        ICommunityToken ct = ICommunityToken(token);
        shopDisplay = ct.rawBalanceToDisplayBalance(shopRaw);
        communityDisplay = ct.rawBalanceToDisplayBalance(communityRaw);
    }

    function _shopAvailable(Shop storage s) internal view returns (uint256) {
        return s.accountedRaw - s.communityAccruedRaw - s.shopOutRaw;
    }

    function _communityAvailable(Shop storage s) internal view returns (uint256) {
        return s.communityAccruedRaw - s.communityOutRaw;
    }

    /// @dev Sends `amount` (display) of the community token from the vault, returning the raw amount moved.
    /// The token may mint to the vault during its own transfer (ARIGATO creation); that increase is credited to the
    /// side(s) that made the transfer, in proportion `communityRaw / raw`.
    function _send(
        address token,
        bytes32 shopId,
        Shop storage s,
        address to,
        uint256 amount,
        uint256 raw,
        uint256 communityRaw
    )
        internal
    {
        address vault = deployVault(token, shopId);
        ShopVault(payable(vault)).withdrawERC20(token, to, amount);
        uint256 total = _totalReceived(token, shopId, s);
        if (total > s.accountedRaw) {
            uint256 extra = total - s.accountedRaw;
            s.accountedRaw = total;
            s.communityAccruedRaw += raw == 0 ? 0 : Math.mulDiv(extra, communityRaw, raw);
        }
    }

    // ---------------------------------------------------------------------
    // Withdraw / refund / rescue
    // ---------------------------------------------------------------------

    function withdrawShopShare(address token, bytes32 shopId, uint256 amount) external {
        _withdrawShopShare(msg.sender, token, shopId, amount);
    }

    /// @dev Members with WITHDRAW may withdraw the shop share, always to the payout address set by the owner.
    function _withdrawShopShare(address sender, address token, bytes32 shopId, uint256 amount) internal {
        Shop storage s = _registered(token, shopId);
        if (!hasPermission(token, shopId, sender, PERM_WITHDRAW)) revert NotAuthorized();
        _checkpoint(token, shopId, s);
        uint256 raw = ICommunityToken(token).displayBalanceToRawBalance(amount);
        if (raw > _shopAvailable(s)) revert InsufficientShare();
        s.shopOutRaw += raw;
        address to = payoutOf(token, shopId);
        _send(token, shopId, s, to, amount, raw, 0);
        emit ShopShareWithdrawn(token, shopId, to, amount, raw);
    }

    function withdrawCommunityShare(address token, bytes32 shopId, address to, uint256 amount) external {
        _withdrawCommunityShare(msg.sender, token, shopId, to, amount);
    }

    function _withdrawCommunityShare(
        address sender,
        address token,
        bytes32 shopId,
        address to,
        uint256 amount
    )
        internal
    {
        Shop storage s = _registered(token, shopId);
        if (sender == address(0) || sender != communityAdmin[token]) revert NotCommunityAdmin();
        _checkpoint(token, shopId, s);
        uint256 raw = ICommunityToken(token).displayBalanceToRawBalance(amount);
        if (raw > _communityAvailable(s)) revert InsufficientShare();
        s.communityOutRaw += raw;
        _send(token, shopId, s, to, amount, raw, raw);
        emit CommunityShareWithdrawn(token, shopId, to, amount, raw);
    }

    /// @notice Refund from the vault, charged to both shares in the proportion the original payment was split.
    /// The shop part needs a signature from a member with REFUND (a member other than the group owner only through
    /// the refund relayer); the community part needs the community admin's signature. Both sign the same message.
    function refundWithSig(RefundParams calldata p, bytes calldata shopSig, bytes calldata communitySig) external {
        if (block.timestamp > p.deadline) revert SignatureExpired();
        if (refundNonceUsed[p.nonce]) revert NonceAlreadyUsed();
        refundNonceUsed[p.nonce] = true;
        Shop storage s = _registered(p.token, p.shopId);
        _checkpoint(p.token, p.shopId, s);

        uint256 raw = ICommunityToken(p.token).displayBalanceToRawBalance(p.amount);
        uint256 communityRaw = _refundCommunityPart(p, s, raw);
        uint256 shopRaw = raw - communityRaw;

        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(REFUND_TYPEHASH, p.token, p.shopId, p.batchId, p.to, p.amount, p.deadline, p.nonce))
        );
        if (shopRaw > 0) {
            (address signer,,) = ECDSA.tryRecover(digest, shopSig);
            if (!hasPermission(p.token, p.shopId, signer, PERM_REFUND)) revert NotAuthorized();
            if (signer != groupOwner[s.groupId] && msg.sender != refundRelayer) revert NotAuthorized();
            if (shopRaw > _shopAvailable(s)) revert InsufficientShare();
        }
        if (communityRaw > 0) {
            address admin = communityAdmin[p.token];
            (address signer,,) = ECDSA.tryRecover(digest, communitySig);
            if (admin == address(0) || signer != admin) revert NotCommunityAdmin();
            if (communityRaw > _communityAvailable(s)) revert InsufficientShare();
        }
        s.shopOutRaw += shopRaw;
        s.communityOutRaw += communityRaw;
        _send(p.token, p.shopId, s, p.to, p.amount, raw, communityRaw);
        emit Refunded(p.token, p.shopId, p.batchId, p.to, p.amount, shopRaw, communityRaw, p.nonce);
    }

    function _refundCommunityPart(
        RefundParams calldata p,
        Shop storage s,
        uint256 raw
    )
        internal
        returns (uint256 communityRaw)
    {
        if (s.mode == ReceiveMode.SHOP) return 0;
        if (s.mode == ReceiveMode.COMMUNITY) return raw;
        if (p.batchId >= s.batchCount) revert InvalidBatch();
        Batch storage b = _batches[p.token][p.shopId][p.batchId];
        if (b.refundedRaw + raw > b.rawIn) revert RefundExceedsBatch();
        b.refundedRaw += raw;
        communityRaw = Math.mulDiv(raw, b.communityRaw, b.rawIn);
        uint256 back = Math.mulDiv(b.communityDisplay, raw, b.rawIn);
        uint256 total = communityDisplayByPeriod[p.token][p.shopId][b.period];
        communityDisplayByPeriod[p.token][p.shopId][b.period] = total > back ? total - back : 0;
        // A refund in the same period gives the community's room under the cap back.
        if (b.period == s.period) {
            s.periodCommunityDisplay = s.periodCommunityDisplay > back ? s.periodCommunityDisplay - back : 0;
        }
    }

    function rescue(address token, bytes32 shopId, address asset, address to, uint256 amount) external {
        _rescue(msg.sender, token, shopId, asset, to, amount);
    }

    /// @notice Assets other than the community token sent to the vault by mistake (asset 0 = native).
    /// COMMUNITY shops: the community admin, to any address. Others: a member with WITHDRAW, to the payout address.
    function _rescue(
        address sender,
        address token,
        bytes32 shopId,
        address asset,
        address to,
        uint256 amount
    )
        internal
    {
        Shop storage s = _registered(token, shopId);
        if (asset == token) revert UseShareWithdraw();
        if (s.mode == ReceiveMode.COMMUNITY) {
            if (sender == address(0) || sender != communityAdmin[token]) revert NotCommunityAdmin();
        } else {
            if (!hasPermission(token, shopId, sender, PERM_WITHDRAW)) revert NotAuthorized();
            to = payoutOf(token, shopId);
        }
        ShopVault vault = ShopVault(payable(deployVault(token, shopId)));
        if (asset == address(0)) {
            vault.withdrawNative(to, amount);
        } else {
            vault.withdrawERC20(asset, to, amount);
        }
        emit Rescued(token, shopId, asset, to, amount);
    }

    // ---------------------------------------------------------------------
    // EIP-712 signature entry points (anyone may relay; relayer pays gas)
    // ---------------------------------------------------------------------

    function _recover(bytes32 structHash, uint256 deadline, bytes calldata sig) internal view returns (address) {
        if (block.timestamp > deadline) revert SignatureExpired();
        return ECDSA.recover(_hashTypedDataV4(structHash), sig);
    }

    function _useNonce(address signer, bytes32 nonce) internal {
        if (nonceUsed[signer][nonce]) revert NonceAlreadyUsed();
        nonceUsed[signer][nonce] = true;
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @dev Replay is prevented by AlreadyRegistered (one registration per shopId).
    function registerShopWithSig(RegisterParams calldata p, uint256 deadline, bytes calldata sig) external {
        bytes32 h = keccak256(
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
                deadline
            )
        );
        _registerShop(_recover(h, deadline, sig), p);
    }

    function setCommunityConfigWithSig(
        address token,
        bool allow,
        uint256 maxCap,
        bytes32 termsHash,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata sig
    )
        external
    {
        address signer = _recover(
            keccak256(abi.encode(SET_COMMUNITY_CONFIG_TYPEHASH, token, allow, maxCap, termsHash, deadline, nonce)),
            deadline,
            sig
        );
        _useNonce(signer, nonce);
        _setCommunityConfig(signer, token, allow, maxCap, termsHash);
    }

    function setGroupPermissionWithSig(
        bytes32 groupId,
        address account,
        uint8 permissions,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata sig
    )
        external
    {
        address signer = _recover(
            keccak256(abi.encode(SET_GROUP_PERMISSION_TYPEHASH, groupId, account, permissions, deadline, nonce)),
            deadline,
            sig
        );
        _useNonce(signer, nonce);
        _setGroupPermission(signer, groupId, account, permissions);
    }

    function setShopPermissionWithSig(
        address token,
        bytes32 shopId,
        address account,
        uint8 permissions,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata sig
    )
        external
    {
        address signer = _recover(
            keccak256(abi.encode(SET_SHOP_PERMISSION_TYPEHASH, token, shopId, account, permissions, deadline, nonce)),
            deadline,
            sig
        );
        _useNonce(signer, nonce);
        _setShopPermission(signer, token, shopId, account, permissions);
    }

    function setPayoutWithSig(
        address token,
        bytes32 shopId,
        address payout,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata sig
    )
        external
    {
        address signer =
            _recover(keccak256(abi.encode(SET_PAYOUT_TYPEHASH, token, shopId, payout, deadline, nonce)), deadline, sig);
        _useNonce(signer, nonce);
        _setPayout(signer, token, shopId, payout);
    }

    function withdrawShopShareWithSig(
        address token,
        bytes32 shopId,
        uint256 amount,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata sig
    )
        external
    {
        address signer = _recover(
            keccak256(abi.encode(WITHDRAW_SHOP_SHARE_TYPEHASH, token, shopId, amount, deadline, nonce)), deadline, sig
        );
        _useNonce(signer, nonce);
        _withdrawShopShare(signer, token, shopId, amount);
    }

    function withdrawCommunityShareWithSig(
        address token,
        bytes32 shopId,
        address to,
        uint256 amount,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata sig
    )
        external
    {
        address signer = _recover(
            keccak256(abi.encode(WITHDRAW_COMMUNITY_SHARE_TYPEHASH, token, shopId, to, amount, deadline, nonce)),
            deadline,
            sig
        );
        _useNonce(signer, nonce);
        _withdrawCommunityShare(signer, token, shopId, to, amount);
    }

    function rescueWithSig(
        address token,
        bytes32 shopId,
        address asset,
        address to,
        uint256 amount,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata sig
    )
        external
    {
        address signer = _recover(
            keccak256(abi.encode(RESCUE_TYPEHASH, token, shopId, asset, to, amount, deadline, nonce)), deadline, sig
        );
        _useNonce(signer, nonce);
        _rescue(signer, token, shopId, asset, to, amount);
    }
}
