// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { PIP23ArtifactHelper } from "./fixtures/PIP23ArtifactHelper.sol";
import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IERC5805 } from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import { Upgrades, Options } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { PCEGovernor } from "../src/PCEGovernor.sol";
import { IPCEGovernorV2 } from "./fixtures/IPCEGovernorV2.sol";
import { PCEMainnetToken } from "../src/PCEMainnetToken.sol";

contract PIP23TimestampClock {
    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=timestamp";
    }
}

contract PIP23RevertingClock {
    function CLOCK_MODE() external pure returns (string memory) {
        revert("no clock");
    }
}

contract PIP23Target {
    uint256 public value;

    function setValue(uint256 newValue) external {
        value = newValue;
    }
}

abstract contract PIP23GovernanceTestBase is PIP23ArtifactHelper {
    PCEGovernor internal governor;
    TimelockController internal timelock;
    PCEMainnetToken internal newToken;
    IPCEGovernorV2 internal v2;
    IERC5805 internal oldToken;
    address[3] internal voters;
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _deployToken(address owner) internal returns (PCEMainnetToken) {
        address impl = deployCode("PCEMainnetToken.sol:PCEMainnetToken");
        return PCEMainnetToken(address(new ERC1967Proxy(impl, abi.encodeCall(PCEMainnetToken.initialize, (owner)))));
    }

    function _queue(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calls,
        string memory description
    )
        internal
        returns (uint256 id)
    {
        vm.prank(voters[0]);
        id = governor.propose(targets, values, calls, description);
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Pending));
        vm.roll(governor.proposalSnapshot(id) + 1);
        for (uint256 i; i < voters.length; ++i) {
            vm.prank(voters[i]);
            governor.castVote(id, 1);
        }
        vm.roll(governor.proposalDeadline(id) + 1);
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Succeeded));
        governor.queue(targets, values, calls, keccak256(bytes(description)));
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Queued));
    }

    function _migration(
        address[] memory recipients,
        uint256[] memory amounts,
        IVotes votingToken
    )
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calls)
    {
        targets = new address[](2);
        values = new uint256[](2);
        calls = new bytes[](2);
        targets[0] = address(newToken);
        targets[1] = address(governor);
        calls[0] = abi.encodeCall(PCEMainnetToken.distribute, (recipients, amounts));
        calls[1] = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)",
            address(v2),
            abi.encodeCall(IPCEGovernorV2.switchVotingToken, (votingToken))
        );
    }

    function _oneAction(
        address target,
        bytes memory callData
    )
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calls)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calls = new bytes[](1);
        targets[0] = target;
        calls[0] = callData;
    }

    function _assertRules() internal view {
        assertEq(governor.votingDelay(), 7200);
        assertEq(governor.votingPeriod(), 21_600);
        assertEq(governor.proposalThreshold(), 1000 ether);
        assertEq(governor.quorum(block.number - 1), 500_000 ether);
        assertEq(governor.absoluteQuorum(), 500_000 ether);
        assertEq(governor.COUNTING_MODE(), "support=bravo&quorum=for,abstain");
        assertEq(governor.CLOCK_MODE(), "mode=blocknumber&from=default");
        assertEq(governor.clock(), block.number);
        assertEq(governor.timelock(), address(timelock));
    }
}

contract PCEGovernorV2Test is PIP23GovernanceTestBase {
    function setUp() public {
        vm.roll(100);
        voters = [makeAddr("voter1"), makeAddr("voter2"), makeAddr("voter3")];
        address[] memory none = new address[](0);
        address[] memory executors = new address[](1);
        timelock = TimelockController(
            payable(deployCode(
                    "TimelockController.sol:TimelockController", abi.encode(2 days, none, executors, address(this))
                ))
        );
        PCEMainnetToken old = _deployToken(address(this));
        oldToken = IERC5805(address(old));
        address impl = _deployGovernorArtifact("out-governor-mainnet/PCEGovernor.sol/PCEGovernor.json");
        governor = PCEGovernor(
            payable(address(
                    new ERC1967Proxy(
                        impl,
                        abi.encodeCall(
                            PCEGovernor.initialize,
                            (
                                "PCE DAO",
                                address(old),
                                address(timelock),
                                7200,
                                21_600,
                                1000 ether,
                                address(old),
                                500_000 ether
                            )
                        )
                    )
                ))
        );
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));
        newToken = _deployToken(address(timelock));
        v2 = IPCEGovernorV2(
            payable(_deployGovernorArtifact("out-governor-mainnet/PCEGovernorV2.sol/PCEGovernorV2.json"))
        );
        (address[] memory r, uint256[] memory a) = _voterDistribution();
        old.distribute(r, a);
        for (uint256 i; i < voters.length; ++i) {
            vm.prank(voters[i]);
            old.delegate(voters[i]);
        }
        vm.roll(block.number + 1);
    }

    function _voterDistribution() internal view returns (address[] memory r, uint256[] memory a) {
        r = new address[](3);
        a = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            r[i] = voters[i];
            a[i] = 200_000 ether;
        }
    }

    function _upgradeWithoutSwitch() internal {
        vm.prank(address(timelock));
        governor.upgradeToAndCall(address(v2), "");
    }

    function _upgradeAndSwitch() internal {
        vm.prank(address(timelock));
        governor.upgradeToAndCall(
            address(v2), abi.encodeCall(IPCEGovernorV2.switchVotingToken, (IVotes(address(newToken))))
        );
    }

    function testUpgradeAndSwitchPreservesRulesAndStorage() public {
        bytes32[5] memory beforeSlots;
        for (uint256 i; i < 5; ++i) {
            beforeSlots[i] = vm.load(address(governor), bytes32(i));
        }
        string memory name = governor.name();
        vm.expectEmit(true, true, false, false, address(governor));
        emit IPCEGovernorV2.VotingTokenSwitched(address(oldToken), address(newToken));
        _upgradeAndSwitch();
        assertEq(address(governor.token()), address(newToken));
        assertEq(governor.name(), name);
        _assertRules();
        for (uint256 i; i < 5; ++i) {
            assertEq(vm.load(address(governor), bytes32(i)), beforeSlots[i]);
        }
    }

    function testOnlyExecutorAndFailedCallDoesNotConsumeVersion() public {
        _upgradeWithoutSwitch();
        vm.prank(voters[0]);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, voters[0]));
        IPCEGovernorV2(payable(address(governor))).switchVotingToken(IVotes(address(newToken)));
        vm.prank(address(timelock));
        IPCEGovernorV2(payable(address(governor))).switchVotingToken(IVotes(address(newToken)));
        assertEq(address(governor.token()), address(newToken));
    }

    function testNonExecutorAfterSwitchStillGetsGovernorOnlyExecutor() public {
        _upgradeAndSwitch();
        vm.prank(voters[0]);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, voters[0]));
        IPCEGovernorV2(payable(address(governor))).switchVotingToken(IVotes(address(oldToken)));
    }

    function testSwitchCannotRunTwice() public {
        _upgradeAndSwitch();
        vm.prank(address(timelock));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        IPCEGovernorV2(payable(address(governor))).switchVotingToken(IVotes(address(oldToken)));
    }

    function testInvalidTokens() public {
        _upgradeWithoutSwitch();
        address[5] memory invalid = [
            address(0),
            address(oldToken),
            address(new PIP23TimestampClock()),
            address(new PIP23RevertingClock()),
            makeAddr("noCode")
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.prank(address(timelock));
            vm.expectRevert(IPCEGovernorV2.InvalidVotingToken.selector);
            IPCEGovernorV2(payable(address(governor))).switchVotingToken(IVotes(invalid[i]));
            assertEq(address(governor.token()), address(oldToken));
        }
        vm.prank(address(timelock));
        IPCEGovernorV2(payable(address(governor))).switchVotingToken(IVotes(address(newToken)));
    }

    function testImplementationLockedAndInitializeCannotRepeat() public {
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, address(this)));
        v2.switchVotingToken(IVotes(address(newToken)));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v2.initialize("bad", address(oldToken), address(timelock), 1, 1, 1, address(oldToken), 1);
        _upgradeAndSwitch();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        governor.initialize("bad", address(oldToken), address(timelock), 1, 1, 1, address(oldToken), 1);
    }

    function testUpgradeOnlyTimelock() public {
        vm.prank(voters[0]);
        vm.expectRevert("Only timelock");
        governor.upgradeToAndCall(address(v2), "");
    }

    function testDAOProposalMigratesAtomicallyAndNewVotesCanGovern() public {
        (address[] memory r, uint256[] memory a) = _voterDistribution();
        (address[] memory targets, uint256[] memory values, bytes[] memory calls) =
            _migration(r, a, IVotes(address(newToken)));
        uint256 id = _queue(targets, values, calls, "PIP-23 migration");
        vm.warp(governor.proposalEta(id));
        governor.execute(targets, values, calls, keccak256("PIP-23 migration"));
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Executed));
        assertEq(address(governor.token()), address(newToken));
        assertEq(newToken.totalSupply(), 600_000 ether);
        _assertRules();
        for (uint256 i; i < voters.length; ++i) {
            assertEq(newToken.getVotes(voters[i]), 0);
            vm.prank(voters[i]);
            newToken.delegate(voters[i]);
        }
        vm.roll(block.number + 1);
        (targets, values, calls) = _oneAction(address(newToken), abi.encodeCall(PCEMainnetToken.closeDistribution, ()));
        id = _queue(targets, values, calls, "New PCE governance");
        vm.warp(governor.proposalEta(id));
        governor.execute(targets, values, calls, keccak256("New PCE governance"));
        assertTrue(newToken.distributionClosed());
    }

    function testRevertingSwitchRollsBackMintAndUpgrade() public {
        (address[] memory r, uint256[] memory a) = _voterDistribution();
        (address[] memory targets, uint256[] memory values, bytes[] memory calls) =
            _migration(r, a, IVotes(address(new PIP23TimestampClock())));
        uint256 id = _queue(targets, values, calls, "Invalid migration");
        bytes32 oldImpl = vm.load(address(governor), IMPLEMENTATION_SLOT);
        vm.warp(governor.proposalEta(id));
        vm.expectRevert(IPCEGovernorV2.InvalidVotingToken.selector);
        governor.execute(targets, values, calls, keccak256("Invalid migration"));
        assertEq(vm.load(address(governor), IMPLEMENTATION_SLOT), oldImpl);
        assertEq(address(governor.token()), address(oldToken));
        assertEq(newToken.totalSupply(), 0);
        for (uint256 i; i < voters.length; ++i) {
            assertEq(newToken.balanceOf(voters[i]), 0);
        }
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Queued));
    }

    function _voteWithNewToken(
        uint8[3] memory support,
        uint256 extraFirstVoter
    )
        internal
        returns (IGovernor.ProposalState)
    {
        (address[] memory r, uint256[] memory a) = _voterDistribution();
        a[0] += extraFirstVoter;
        vm.prank(address(timelock));
        newToken.distribute(r, a);
        _upgradeAndSwitch();
        for (uint256 i; i < voters.length; ++i) {
            vm.prank(voters[i]);
            newToken.delegate(voters[i]);
        }
        vm.roll(block.number + 1);
        (address[] memory targets, uint256[] memory values, bytes[] memory calls) =
            _oneAction(address(newToken), abi.encodeCall(PCEMainnetToken.closeDistribution, ()));
        vm.prank(voters[0]);
        uint256 id = governor.propose(targets, values, calls, "Voting rules after switch");
        vm.roll(governor.proposalSnapshot(id) + 1);
        for (uint256 i; i < voters.length; ++i) {
            if (support[i] > 2) continue;
            vm.prank(voters[i]);
            governor.castVote(id, support[i]);
        }
        vm.roll(governor.proposalDeadline(id) + 1);
        return governor.state(id);
    }

    function testQuorumCountsForAndAbstainAfterSwitch() public {
        assertEq(uint256(_voteWithNewToken([uint8(1), 2, 2], 0)), uint256(IGovernor.ProposalState.Succeeded));
    }

    function testTieIsDefeatedAfterSwitch() public {
        assertEq(uint256(_voteWithNewToken([uint8(1), 0, 2], 0)), uint256(IGovernor.ProposalState.Defeated));
    }

    function testBelowQuorumIsDefeatedAfterSwitch() public {
        assertEq(uint256(_voteWithNewToken([uint8(1), 1, 255], 0)), uint256(IGovernor.ProposalState.Defeated));
    }

    function testAgainstDoesNotCountTowardQuorumAfterSwitch() public {
        // 400k For beats 200k Against, but For + Abstain still misses the 500k quorum.
        assertEq(uint256(_voteWithNewToken([uint8(1), 1, 0], 0)), uint256(IGovernor.ProposalState.Defeated));
    }

    function testSimpleMajorityNotTwoThirdsAfterSwitch() public {
        // 300k For + 200k Abstain reaches quorum; 300k For beats 200k Against (60%, not 66%).
        assertEq(
            uint256(_voteWithNewToken([uint8(1), 0, 2], 100_000 ether)), uint256(IGovernor.ProposalState.Succeeded)
        );
    }

    function testQueuedProposalSurvivesSwitch() public {
        PIP23Target target = new PIP23Target();
        (address[] memory targets, uint256[] memory values, bytes[] memory calls) =
            _oneAction(address(target), abi.encodeCall(PIP23Target.setValue, (7)));
        uint256 id = _queue(targets, values, calls, "Queued before switch");
        _upgradeAndSwitch();
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Queued));
        vm.warp(governor.proposalEta(id));
        governor.execute(targets, values, calls, keccak256("Queued before switch"));
        assertEq(target.value(), 7);
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Executed));
    }
}

contract PIP23UpgradeValidationTest is Test {
    function testValidateTokenImplementation() public {
        Options memory opts;
        Upgrades.validateImplementation("PCEMainnetToken.sol:PCEMainnetToken", opts);
    }
}

contract PIP23ArtifactPreflightTest is PIP23GovernanceTestBase {
    function testMissingGovernorArtifactHasActionableError() public {
        string memory artifact = "out-governor-mainnet/__missing_pip23_artifact__.json";
        assertFalse(vm.exists(artifact));
        vm.expectRevert(
            bytes(
                string.concat(
                    "Missing governor_mainnet artifact: ",
                    artifact,
                    ". Run FORGE=/path/to/forge-1.7.1 npm run build:pip23 before direct forge test."
                )
            )
        );
        this.deployArtifact(artifact);
    }

    function deployArtifact(string memory artifact) external returns (address) {
        return _deployGovernorArtifact(artifact);
    }
}
