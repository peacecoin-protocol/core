// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable,
    NoncesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {
    ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice Ethereum PCE, distributed and upgraded exclusively by its DAO Timelock owner.
contract PCEMainnetToken is
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    /// @custom:storage-location erc7201:peacecoin.storage.PCEToken
    struct PCETokenStorage {
        bool distributionClosed;
    }

    // keccak256(abi.encode(uint256(keccak256("peacecoin.storage.PCEToken")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PCE_TOKEN_STORAGE_LOCATION =
        0x3629129d1ffd87df7c2b731c970b9f725273df030c447616868b5704115a1a00;

    error DistributionIsClosed();
    error EmptyDistribution();
    error LengthMismatch();
    error ZeroRecipient();
    error ZeroAmount();
    error RenounceOwnershipDisabled();

    event Distributed(address indexed recipient, uint256 amount);
    event DistributionClosed(uint256 totalSupply);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Call through the proxy constructor, with the Ethereum Timelock as initialOwner.
    function initialize(address initialOwner) external initializer {
        __ERC20_init("PEACE COIN", "PCE");
        __ERC20Permit_init("PEACE COIN");
        __ERC20Votes_init();
        __Ownable_init(initialOwner);
    }

    function distribute(address[] calldata recipients, uint256[] calldata amounts) external onlyOwner {
        if (distributionClosed()) revert DistributionIsClosed();
        if (recipients.length == 0) revert EmptyDistribution();
        if (recipients.length != amounts.length) revert LengthMismatch();
        for (uint256 i = 0; i < recipients.length; ++i) {
            if (recipients[i] == address(0)) revert ZeroRecipient();
            if (amounts[i] == 0) revert ZeroAmount();
            _mint(recipients[i], amounts[i]);
            emit Distributed(recipients[i], amounts[i]);
        }
    }

    function closeDistribution() external onlyOwner {
        PCETokenStorage storage $ = _getPCETokenStorage();
        if ($.distributionClosed) revert DistributionIsClosed();
        $.distributionClosed = true;
        emit DistributionClosed(totalSupply());
    }

    function distributionClosed() public view returns (bool) {
        return _getPCETokenStorage().distributionClosed;
    }

    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    function clock() public view override returns (uint48) {
        return uint48(block.number);
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=blocknumber&from=default";
    }

    function nonces(address account) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
        return super.nonces(account);
    }

    function _update(
        address from,
        address to,
        uint256 amount
    )
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        super._update(from, to, amount);
    }

    function _authorizeUpgrade(address) internal override onlyOwner { }

    function _getPCETokenStorage() private pure returns (PCETokenStorage storage $) {
        assembly {
            $.slot := PCE_TOKEN_STORAGE_LOCATION
        }
    }
}
