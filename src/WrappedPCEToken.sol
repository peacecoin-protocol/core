// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20WrapperUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title WrappedPCEToken
 * @dev Wrapped version of PeaceCoin Token (WPCE) with voting capabilities for DAO governance.
 *
 * Features:
 * - 1:1 exchange rate with the underlying PCE token
 * - ERC20Votes for Tally DAO governance
 * - UUPS upgradeable pattern
 * - No restrictions on wrap/unwrap operations
 */
contract WrappedPCEToken is
    ERC20WrapperUpgradeable,
    ERC20VotesUpgradeable,
    ERC20PermitUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the wrapped token contract
     * @param _name Token name (e.g., "Wrapped PeaceCoin Token")
     * @param _symbol Token symbol (e.g., "WPCE")
     * @param _pceToken Address of the underlying PCE token to wrap
     * @param _owner Address of the contract owner
     */
    function initialize(
        string memory _name,
        string memory _symbol,
        address _pceToken,
        address _owner
    ) public initializer {
        require(_pceToken != address(0), "WrappedPCE: PCE token is zero address");
        require(_owner != address(0), "WrappedPCE: Owner is zero address");

        __ERC20_init(_name, _symbol);
        __ERC20Wrapper_init(IERC20(_pceToken));
        __ERC20Votes_init();
        __ERC20Permit_init(_name);
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
    }

    /**
     * @notice Returns the underlying PCE token
     * @return The PCE token address
     */
    function pceToken() external view returns (IERC20) {
        return underlying();
    }


    /**
     * @notice Clock for voting snapshots (uses block numbers)
     */
    function clock() public view virtual override returns (uint48) {
        return uint48(block.number);
    }

    /**
     * @notice Clock mode for voting snapshots
     */
    function CLOCK_MODE() public pure virtual override returns (string memory) {
        return "mode=blocknumber&from=default";
    }

    // Required overrides for multiple inheritance

    function decimals() public view virtual override(ERC20Upgradeable, ERC20WrapperUpgradeable) returns (uint8) {
        return super.decimals();
    }

    function _update(
        address from,
        address to,
        uint256 amount
    ) internal virtual override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        super._update(from, to, amount);
    }

    function nonces(address owner)
        public
        view
        virtual
        override(ERC20PermitUpgradeable, NoncesUpgradeable)
        returns (uint256)
    {
        return super.nonces(owner);
    }


    /**
     * @notice Batch approve and wrap PCE tokens in one call
     * @dev Designed for EIP-7702 delegated calls from EOAs
     * @param amount Amount of PCE tokens to wrap
     */
    function approveAndWrap(uint256 amount) external returns (bool) {
        // When called via EIP-7702, msg.sender is the EOA that delegated
        IERC20 token = underlying();
        
        // Approve this contract to spend tokens
        token.approve(address(this), amount);
        
        // Wrap the tokens
        return depositFor(msg.sender, amount);
    }
    
    /**
     * @notice Check if caller is a smart contract or EOA with code (EIP-7702)
     * @return True if caller has code (contract or delegated EOA)
     */
    function callerHasCode() external view returns (bool) {
        return msg.sender.code.length > 0;
    }

    /**
     * @notice Authorizes contract upgrades (only owner)
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
