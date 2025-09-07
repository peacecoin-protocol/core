// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
    GovernorTimelockControlUpgradeable,
    UUPSUpgradeable
{
    uint256 private _votingDelay;
    uint256 private _votingPeriod;
    uint256 private _proposalThreshold;
    IERC20 private _quorumSupplyToken;
    uint256 private _absoluteQuorum;
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
        address _quorumToken,
        uint256 _absoluteQuorumValue
    ) public initializer {
        __Governor_init(_name);
        __GovernorCountingSimple_init();
        __GovernorVotes_init(IVotes(_token));
        __GovernorTimelockControl_init(TimelockControllerUpgradeable(payable(_timelock)));
        __UUPSUpgradeable_init();

        _votingDelay = _vDelay;
        _votingPeriod = _vPeriod;
        _proposalThreshold = _pThreshold;
        require(_quorumToken != address(0), "Invalid quorum token");
        _quorumSupplyToken = IERC20(_quorumToken);
        require(_absoluteQuorumValue > 0, "Invalid absolute quorum");
        _absoluteQuorum = _absoluteQuorumValue;
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

    function quorum(uint256)
        public
        view
        override(GovernorUpgradeable)
        returns (uint256)
    {
        // Absolute quorum in token units (18 decimals). Ignores percentage-based calculation.
        return _absoluteQuorum;
    }

    function absoluteQuorum() public view returns (uint256) {
        return _absoluteQuorum;
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
