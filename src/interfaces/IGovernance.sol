// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Possible states that a proposal may be in
enum ProposalState {
    Pending,
    Active,
    Canceled,
    Defeated,
    Succeeded,
    Queued,
    Expired,
    Executed
}

interface IGovernance {
    function state(uint proposalId) external view returns (ProposalState);
    function proposer(uint proposalId) external view returns (address);
    function proposalCount() external view returns (uint256);
}
