// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IGovernance, ProposalState} from "./interfaces/IGovernance.sol";

contract Bounty is Initializable, OwnableUpgradeable {
    struct BountyInfo {
        uint256 bountyAmount;
        uint256 withdrawn;
    }

    event UpdatedBountyAmount(uint256 bountyAmount);
    event AddedContributorBounty(
        address indexed user,
        address indexed contributor,
        uint256 amount
    );
    event AddedProposalBounty(
        address indexed user,
        uint256 indexed proposalId,
        uint256 amount
    );
    event ClaimedBounty(address indexed user, uint256 amount);

    uint256 public bountyAmount;
    ERC20Upgradeable public bountyToken;
    address public governance;

    mapping(uint256 => uint256) public proposalBounties;
    mapping(address => uint256) public proposalBountyWithdrawn;
    mapping(address => BountyInfo) public contributorBounties;
    mapping(address => bool) public isContributor;

    function initialize(
        ERC20Upgradeable _bountyToken,
        uint256 _bountyAmount,
        address _governance
    ) public initializer {
        __Ownable_init(msg.sender);
        bountyAmount = _bountyAmount;
        bountyToken = _bountyToken;
        governance = _governance;
    }

    function setBountyAmount(uint256 _bountyAmount) external onlyOwner {
        bountyAmount = _bountyAmount;
        emit UpdatedBountyAmount(_bountyAmount);
    }

    function setContributor(
        address _contributor,
        bool status
    ) external onlyOwner {
        require(_contributor != address(0), "Invalid contributor");
        isContributor[_contributor] = status;
    }

    function addProposalBounty(uint256 _proposalId, uint256 _amount) external {
        require(_amount > 0, "Amount must be greater than 0");
        require(
            IGovernance(governance).state(_proposalId) ==
                ProposalState.Executed ||
                IGovernance(governance).state(_proposalId) ==
                ProposalState.Succeeded,
            "Invalid proposal state"
        );

        proposalBounties[_proposalId] += _amount;
        bountyToken.transferFrom(msg.sender, address(this), _amount);

        emit AddedProposalBounty(msg.sender, _proposalId, _amount);
    }

    function addContributorBounty(
        address _contributor,
        uint256 _amount
    ) external {
        require(_amount > 0, "Amount must be greater than 0");
        require(_contributor != address(0), "Invalid contributor");

        BountyInfo storage bounty = contributorBounties[_contributor];
        bounty.bountyAmount += _amount;

        bountyToken.transferFrom(msg.sender, address(this), _amount);

        emit AddedContributorBounty(msg.sender, _contributor, _amount);
    }

    function claimProposalBounty() external {
        uint256 claimable = claimableProposalAmount(msg.sender);

        require(claimable > 0, "Nothing to withdraw");

        proposalBountyWithdrawn[msg.sender] += claimable;
        bountyToken.transfer(msg.sender, claimable);

        emit ClaimedBounty(msg.sender, claimable);
    }

    function claimContributorBounty() external {
        uint256 claimable = claimableContributorAmount(msg.sender);
        require(claimable > 0, "Nothing to withdraw");

        BountyInfo storage bounty = contributorBounties[msg.sender];
        bounty.withdrawn += claimable;
        bountyToken.transfer(msg.sender, claimable);

        emit ClaimedBounty(msg.sender, claimable);
    }

    function claimableProposalAmount(
        address _user
    ) public view returns (uint256) {
        uint256 _totalBounty;
        uint256 proposalCount = IGovernance(governance).proposalCount();
        for (uint256 i = 0; i < proposalCount; i++) {
            address proposer = IGovernance(governance).proposer(i);

            if (proposer == _user) {
                _totalBounty += proposalBounties[i] + bountyAmount;
            }
        }
        return _totalBounty - proposalBountyWithdrawn[_user];
    }

    function claimableContributorAmount(
        address user
    ) public view returns (uint256) {
        uint256 extraAmount = isContributor[user] ? bountyAmount : 0;
        BountyInfo storage bounty = contributorBounties[msg.sender];
        uint256 claimable = bounty.bountyAmount +
            extraAmount -
            bounty.withdrawn;
        return claimable;
    }

    function recoverERC20(ERC20Upgradeable token) external onlyOwner {
        token.transfer(msg.sender, token.balanceOf(address(this)));
    }
}
