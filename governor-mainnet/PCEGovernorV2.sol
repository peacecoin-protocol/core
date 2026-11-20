// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PCEGovernor } from "./PCEGovernor.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IERC6372 } from "@openzeppelin/contracts/interfaces/IERC6372.sol";

/// @notice PIP-23 voting-token migration; no new storage or changes to voting rules.
/// @custom:oz-upgrades-from governor-mainnet/PCEGovernor.sol:PCEGovernor
contract PCEGovernorV2 is PCEGovernor {
    error InvalidVotingToken();

    event VotingTokenSwitched(address indexed oldToken, address indexed newToken);

    modifier onlyMigrationExecutor() {
        if (msg.sender != _executor()) revert GovernorOnlyExecutor(msg.sender);
        _;
    }

    /// @dev Called atomically through upgradeToAndCall by the Timelock. onlyGovernance
    /// cannot be used here: its calldata queue contains the outer upgrade call.
    function switchVotingToken(IVotes newToken) external onlyMigrationExecutor reinitializer(2) {
        address oldToken = address(token());
        if (address(newToken).code.length == 0 || address(newToken) == oldToken) revert InvalidVotingToken();
        // Missing/reverting clocks are invalid too; do not silently accept Governor's fallback.
        try IERC6372(address(newToken)).CLOCK_MODE() returns (string memory mode) {
            if (keccak256(bytes(mode)) != keccak256(bytes(CLOCK_MODE()))) revert InvalidVotingToken();
        } catch {
            revert InvalidVotingToken();
        }
        __GovernorVotes_init_unchained(newToken);
        emit VotingTokenSwitched(oldToken, address(newToken));
    }
}
