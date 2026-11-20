// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @dev ABI only. Deploy the separately compiled OZ 5.0.2 artifact, never a default-profile V2.
interface IPCEGovernorV2 {
    error InvalidVotingToken();
    event VotingTokenSwitched(address indexed oldToken, address indexed newToken);

    function switchVotingToken(IVotes newToken) external;
    function initialize(
        string memory name,
        address token,
        address timelock,
        uint256 votingDelay,
        uint256 votingPeriod,
        uint256 proposalThreshold,
        address quorumToken,
        uint256 absoluteQuorum
    )
        external;
}
