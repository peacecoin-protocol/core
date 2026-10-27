// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ShopVault } from "./ShopVault.sol";

/// @notice Deploys ShopVault clones at deterministic addresses and enforces who may withdraw.
/// Vault address = CREATE2(factory, keccak256(abi.encode(token, shopId)), keccak256(cloneInitCode(implementation))).
contract ShopVaultFactory is Ownable {
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

    event CommunityAdminSet(address indexed token, address admin);
    event WithdrawPolicySet(address indexed token, WithdrawPolicy policy);
    event ShopRegistered(address indexed token, bytes32 indexed shopId, address manager, address vault);
    event ShopWithdrawerSet(address indexed token, bytes32 indexed shopId, address account, bool allowed);
    event VaultDeployed(address indexed token, bytes32 indexed shopId, address vault);

    constructor(address owner_) Ownable(owner_) {
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
        if (msg.sender != communityAdmin[token]) revert NotCommunityAdmin();
        withdrawPolicy[token] = policy;
        emit WithdrawPolicySet(token, policy);
    }

    /// @notice Self-registration: caller becomes the shop manager. No approval needed.
    function registerShop(address token, bytes32 shopId, address manager) external {
        if (shopManager[token][shopId] != address(0)) revert AlreadyRegistered();
        if (msg.sender != manager) revert NotShopManager();
        shopManager[token][shopId] = manager;
        emit ShopRegistered(token, shopId, manager, predict(token, shopId));
    }

    function setShopWithdrawer(address token, bytes32 shopId, address account, bool allowed) external {
        if (msg.sender != shopManager[token][shopId]) revert NotShopManager();
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
        if (!canWithdraw(token, shopId, msg.sender)) revert NotAuthorized();
        ShopVault(payable(deployVault(token, shopId))).withdrawERC20(erc20, to, amount);
    }

    function withdrawNative(address token, bytes32 shopId, address to, uint256 amount) external {
        if (!canWithdraw(token, shopId, msg.sender)) revert NotAuthorized();
        ShopVault(payable(deployVault(token, shopId))).withdrawNative(to, amount);
    }
}
