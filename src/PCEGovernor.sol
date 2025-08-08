// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesQuorumFractionUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title PCEGovernor
 * @dev Governor contract for PCE token holders to create and vote on proposals
 * 
 * This contract enables:
 * - Creating proposals for protocol changes
 * - Voting with PCE tokens
 * - Executing approved proposals after timelock
 * - Compatible with Tally interface
 */
contract PCEGovernor is 
    GovernorUpgradeable,
    GovernorCountingSimpleUpgradeable,
    GovernorVotesUpgradeable,
    GovernorVotesQuorumFractionUpgradeable,
    GovernorTimelockControlUpgradeable,
    UUPSUpgradeable
{
    uint256 private _votingDelay;
    uint256 private _votingPeriod;
    uint256 private _proposalThreshold;
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory _name,
        address _token,
        address _timelock,
        uint256 _vDelay,
        uint256 _vPeriod,
        uint256 _pThreshold,
        uint256 _quorumPercentage
    ) public initializer {
        __Governor_init(_name);
        __GovernorCountingSimple_init();
        __GovernorVotes_init(IVotes(_token));
        __GovernorVotesQuorumFraction_init(_quorumPercentage); // 4% quorum
        __GovernorTimelockControl_init(TimelockControllerUpgradeable(payable(_timelock)));
        __UUPSUpgradeable_init();
        
        _votingDelay = _vDelay;
        _votingPeriod = _vPeriod;
        _proposalThreshold = _pThreshold;
    }

    // Required overrides

    function votingDelay()
        public
        view
        override
        returns (uint256)
    {
        return _votingDelay;
    }

    function votingPeriod()
        public
        view
        override
        returns (uint256)
    {
        return _votingPeriod;
    }

    function quorum(uint256 blockNumber)
        public
        view
        override(GovernorUpgradeable, GovernorVotesQuorumFractionUpgradeable)
        returns (uint256)
    {
        return super.quorum(blockNumber);
    }

    function state(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function proposalThreshold()
        public
        view
        override
        returns (uint256)
    {
        return _proposalThreshold;
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (address)
    {
        return super._executor();
    }

    function _authorizeUpgrade(address) internal override {
        require(_executor() == _msgSender(), "Only timelock");
    }
}