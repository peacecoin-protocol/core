// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { ShopVault } from "./ShopVault.sol";

/// @notice Deploys ShopVault clones at deterministic addresses and enforces who may withdraw.
/// Vault address = CREATE2(factory, keccak256(abi.encode(token, shopId)), keccak256(cloneInitCode(implementation))).
contract ShopVaultFactory is Ownable, EIP712 {
    enum WithdrawPolicy {
        SHOP,
        COMMUNITY
    }

    address public immutable implementation;

    /// @dev Simplified model of the community admin; the real version should read it from the community token.
    mapping(address token => address) public communityAdmin;
    mapping(address token => WithdrawPolicy) public withdrawPolicy;
    mapping(address token => mapping(bytes32 shopId => address)) public shopManager;
    mapping(address token => mapping(bytes32 shopId => mapping(address => bool))) public shopWithdrawer;

    error NotCommunityAdmin();
    error NotShopManager();
    error AlreadyRegistered();
    error NotAuthorized();
    error SignatureExpired();
    error NonceAlreadyUsed();

    bytes32 public constant REGISTER_SHOP_TYPEHASH =
        keccak256("RegisterShop(address token,bytes32 shopId,address manager,uint256 deadline)");
    bytes32 public constant SET_WITHDRAW_POLICY_TYPEHASH =
        keccak256("SetWithdrawPolicy(address token,uint8 policy,uint256 deadline,bytes32 nonce)");
    bytes32 public constant SET_SHOP_WITHDRAWER_TYPEHASH = keccak256(
        "SetShopWithdrawer(address token,bytes32 shopId,address account,bool allowed,uint256 deadline,bytes32 nonce)"
    );
    bytes32 public constant WITHDRAW_ERC20_TYPEHASH = keccak256(
        "WithdrawERC20(address token,bytes32 shopId,address erc20,address to,uint256 amount,uint256 deadline,bytes32 nonce)"
    );
    bytes32 public constant WITHDRAW_NATIVE_TYPEHASH = keccak256(
        "WithdrawNative(address token,bytes32 shopId,address to,uint256 amount,uint256 deadline,bytes32 nonce)"
    );

    mapping(address signer => mapping(bytes32 nonce => bool)) public nonceUsed;

    event CommunityAdminSet(address indexed token, address admin);
    event WithdrawPolicySet(address indexed token, WithdrawPolicy policy);
    event ShopRegistered(address indexed token, bytes32 indexed shopId, address manager, address vault);
    event ShopWithdrawerSet(address indexed token, bytes32 indexed shopId, address account, bool allowed);
    event VaultDeployed(address indexed token, bytes32 indexed shopId, address vault);

    constructor(address owner_) Ownable(owner_) EIP712("ShopVaultFactory", "1") {
        implementation = address(new ShopVault());
    }

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

    function setCommunityAdmin(address token, address admin) external onlyOwner {
        communityAdmin[token] = admin;
        emit CommunityAdminSet(token, admin);
    }

    function setWithdrawPolicy(address token, WithdrawPolicy policy) external {
        _setWithdrawPolicy(msg.sender, token, policy);
    }

    function _setWithdrawPolicy(address sender, address token, WithdrawPolicy policy) internal {
        if (sender != communityAdmin[token]) revert NotCommunityAdmin();
        withdrawPolicy[token] = policy;
        emit WithdrawPolicySet(token, policy);
    }

    /// @notice Self-registration: caller becomes the shop manager. No approval needed.
    function registerShop(address token, bytes32 shopId, address manager) external {
        _registerShop(msg.sender, token, shopId, manager);
    }

    function _registerShop(address sender, address token, bytes32 shopId, address manager) internal {
        if (shopManager[token][shopId] != address(0)) revert AlreadyRegistered();
        if (sender != manager) revert NotShopManager();
        shopManager[token][shopId] = manager;
        emit ShopRegistered(token, shopId, manager, predict(token, shopId));
    }

    function setShopWithdrawer(address token, bytes32 shopId, address account, bool allowed) external {
        _setShopWithdrawer(msg.sender, token, shopId, account, allowed);
    }

    function _setShopWithdrawer(
        address sender,
        address token,
        bytes32 shopId,
        address account,
        bool allowed
    )
        internal
    {
        if (sender != shopManager[token][shopId]) revert NotShopManager();
        shopWithdrawer[token][shopId][account] = allowed;
        emit ShopWithdrawerSet(token, shopId, account, allowed);
    }

    function canWithdraw(address token, bytes32 shopId, address account) public view returns (bool) {
        if (withdrawPolicy[token] == WithdrawPolicy.COMMUNITY) {
            return account != address(0) && account == communityAdmin[token];
        }
        address manager = shopManager[token][shopId];
        return manager != address(0) && (account == manager || shopWithdrawer[token][shopId][account]);
    }

    function deployVault(address token, bytes32 shopId) public returns (address vault) {
        vault = predict(token, shopId);
        if (vault.code.length == 0) {
            Clones.cloneDeterministic(implementation, salt(token, shopId));
            ShopVault(payable(vault)).initialize(token, shopId, address(this));
            emit VaultDeployed(token, shopId, vault);
        }
    }

    function withdrawERC20(address token, bytes32 shopId, address erc20, address to, uint256 amount) external {
        _withdrawERC20(msg.sender, token, shopId, erc20, to, amount);
    }

    function withdrawNative(address token, bytes32 shopId, address to, uint256 amount) external {
        _withdrawNative(msg.sender, token, shopId, to, amount);
    }

    function _withdrawERC20(
        address sender,
        address token,
        bytes32 shopId,
        address erc20,
        address to,
        uint256 amount
    )
        internal
    {
        if (!canWithdraw(token, shopId, sender)) revert NotAuthorized();
        ShopVault(payable(deployVault(token, shopId))).withdrawERC20(erc20, to, amount);
    }

    function _withdrawNative(address sender, address token, bytes32 shopId, address to, uint256 amount) internal {
        if (!canWithdraw(token, shopId, sender)) revert NotAuthorized();
        ShopVault(payable(deployVault(token, shopId))).withdrawNative(to, amount);
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
    function registerShopWithSig(
        address token,
        bytes32 shopId,
        address manager,
        uint256 deadline,
        bytes calldata sig
    )
        external
    {
        address signer =
            _recover(keccak256(abi.encode(REGISTER_SHOP_TYPEHASH, token, shopId, manager, deadline)), deadline, sig);
        _registerShop(signer, token, shopId, manager);
    }

    function setWithdrawPolicyWithSig(
        address token,
        WithdrawPolicy policy,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata sig
    )
        external
    {
        address signer = _recover(
            keccak256(abi.encode(SET_WITHDRAW_POLICY_TYPEHASH, token, uint8(policy), deadline, nonce)), deadline, sig
        );
        _useNonce(signer, nonce);
        _setWithdrawPolicy(signer, token, policy);
    }

    function setShopWithdrawerWithSig(
        address token,
        bytes32 shopId,
        address account,
        bool allowed,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata sig
    )
        external
    {
        address signer = _recover(
            keccak256(abi.encode(SET_SHOP_WITHDRAWER_TYPEHASH, token, shopId, account, allowed, deadline, nonce)),
            deadline,
            sig
        );
        _useNonce(signer, nonce);
        _setShopWithdrawer(signer, token, shopId, account, allowed);
    }

    function withdrawERC20WithSig(
        address token,
        bytes32 shopId,
        address erc20,
        address to,
        uint256 amount,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata sig
    )
        external
    {
        address signer = _recover(
            keccak256(abi.encode(WITHDRAW_ERC20_TYPEHASH, token, shopId, erc20, to, amount, deadline, nonce)),
            deadline,
            sig
        );
        _useNonce(signer, nonce);
        _withdrawERC20(signer, token, shopId, erc20, to, amount);
    }

    function withdrawNativeWithSig(
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
            keccak256(abi.encode(WITHDRAW_NATIVE_TYPEHASH, token, shopId, to, amount, deadline, nonce)), deadline, sig
        );
        _useNonce(signer, nonce);
        _withdrawNative(signer, token, shopId, to, amount);
    }
}
