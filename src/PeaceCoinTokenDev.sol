// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title PeaceCoinTokenDev
 * @dev Dev version of the original Peace Coin Token contract for redeployment verification.
 * Updated to Solidity 0.8.26 while maintaining the same functionality.
 *
 * Original contract deployed on Ethereum mainnet at: 0x7c28310CC0b8d898c57b93913098e74a3ba23228
 *
 * The contract embodies the philosophy of sharing and global connection, with the
 * vision that "If everyone in the world share equally, all people will be rich
 * more than they can use. Pass the ARIGATO all over the world."
 */
contract PeaceCoinTokenDev is AccessControl, ERC20, ERC20Burnable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /**
     * @dev If everyone in the world share equally, all people will be rich more than they can use.
     * Pass the "ARIGATO" all over the world.
     */
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(MINTER_ROLE, _msgSender());
    }

    /**
     * @dev Creates `amount` new tokens for `to`.
     *
     * See {ERC20-_mint}.
     *
     * Requirements:
     *
     * - the caller must have the `MINTER_ROLE`.
     */
    function mint(address to, uint256 amount) public {
        require(hasRole(MINTER_ROLE, _msgSender()), "ERC20Minter: must have minter role to mint");
        _mint(to, amount);
    }
}
