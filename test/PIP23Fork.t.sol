// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console2, Vm } from "forge-std/Test.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IERC5805 } from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { PCEGovernor } from "../src/PCEGovernor.sol";
import { IPCEGovernorV2 } from "./fixtures/IPCEGovernorV2.sol";
import { PCEMainnetToken } from "../src/PCEMainnetToken.sol";
import { PIP23GovernanceTestBase, PIP23Target } from "./PCEGovernorV2.t.sol";
import { PIP23DeploymentChecks } from "./fixtures/PIP23DeploymentChecks.sol";
import { DeployPCEMainnetToken } from "../script/DeployPCEMainnetToken.s.sol";
import { PIP23Distribution } from "./fixtures/PIP23Distribution.sol";

interface IPIP23GovernorDeployment {
    function run() external returns (address implementation);
}

/// @dev All actions are local fork simulations. No keys, broadcasts or state writes to the RPC.
/// Run with forge test --isolate for transaction-accurate storage/gas accounting.
abstract contract PIP23ForkBaseTest is PIP23GovernanceTestBase {
    address internal constant GOVERNOR = address(bytes20(hex"00831a36ce3535effefe54bad0bb8de27687a237"));
    address internal constant TIMELOCK = 0x208983f723245C765b4F9E57FAaB2633c9DDaC6B;
    address internal constant WPCE = 0xeB5e0632eD3C635E0fa07420A328b49a7D0E6e6d;
    address internal constant LEGACY_PCE = 0x7c28310CC0b8d898c57b93913098e74a3ba23228;
    address internal constant EXPECTED_IMPLEMENTATION = address(bytes20(hex"911c1f527651374ba6546b1f1510832084af5208"));
    string internal migrationDescription;
    uint256 internal constant EXPECTED_SUPPLY = 222_156_723_489_999_990_835_174_897;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        if (vm.envExists("FORK_BLOCK")) {
            uint256 forkBlock = vm.envUint("FORK_BLOCK");
            vm.createSelectFork(rpc, forkBlock);
            assertEq(block.number, forkBlock, "Fork must use the requested block");
        } else {
            vm.createSelectFork(rpc);
        }
        assertEq(block.chainid, 1);
        console2.log("Fork block", block.number);
        governor = PCEGovernor(payable(GOVERNOR));
        timelock = TimelockController(payable(TIMELOCK));
        oldToken = IERC5805(WPCE);
        assertEq(address(governor.token()), WPCE);
        assertEq(address(uint160(uint256(vm.load(GOVERNOR, IMPLEMENTATION_SLOT)))), EXPECTED_IMPLEMENTATION);
        _assertRules();
        assertEq(timelock.getMinDelay(), 2 days);
        voters = [
            address(bytes20(hex"b50dcfeeaf4885c134f7dbd7e360b57bfd3127c6")),
            address(bytes20(hex"a786629c7d08fd0a6d7fa731ce94e9e3fbe26823")),
            address(bytes20(hex"9052d3da7eebdf4f2b77d1c87fea31c6f789e964"))
        ];
        for (uint256 i; i < voters.length; ++i) {
            assertEq(oldToken.getVotes(voters[i]), 200_000 ether);
            assertEq(oldToken.delegates(voters[i]), voters[i]);
        }
        _configureDeployments();
        assertEq(address(uint160(uint256(vm.load(GOVERNOR, IMPLEMENTATION_SLOT)))), EXPECTED_IMPLEMENTATION);
        // _selectDeployments already checked exact runtime, slots, owner, supply and distribution state.
    }

    // Set all three to rehearse exactly the existing mainnet deployments and production description.
    // The generator receives the same addresses/description; no deployment transactions are simulated.
    // Etherscan verification and the complete Upgraded/role-event history remain separate preconditions.
    function _configureDeployments() internal {
        bool hasToken = vm.envExists("PIP23_NEW_PCE");
        bool hasV2 = vm.envExists("PIP23_GOVERNOR_V2");
        bool hasDescription = vm.envExists("PIP23_DESCRIPTION");
        require(
            (!hasToken && !hasV2 && !hasDescription) || (hasToken && hasV2 && hasDescription),
            "PIP-23: set PIP23_NEW_PCE, PIP23_GOVERNOR_V2 and PIP23_DESCRIPTION together"
        );
        _selectDeployments(
            hasToken,
            hasToken ? vm.envAddress("PIP23_NEW_PCE") : address(0),
            hasV2 ? vm.envAddress("PIP23_GOVERNOR_V2") : address(0),
            vm.envOr("PIP23_DESCRIPTION", string("PIP-23 fork rehearsal"))
        );
    }

    function _selectDeployments(
        bool existing,
        address tokenProxy,
        address implementation,
        string memory description
    )
        internal
    {
        require(bytes(description).length > 0, "PIP-23: empty description");
        migrationDescription = description;
        if (existing) {
            newToken = PCEMainnetToken(tokenProxy);
            v2 = IPCEGovernorV2(implementation);
        } else {
            DeployPCEMainnetToken tokenDeployment =
                DeployPCEMainnetToken(deployCode("DeployPCEMainnetToken.s.sol:DeployPCEMainnetToken"));
            (, address proxy,) = tokenDeployment.run();
            newToken = PCEMainnetToken(proxy);
            IPIP23GovernorDeployment governorDeployment = IPIP23GovernorDeployment(
                _deployGovernorArtifact("out-governor-mainnet/DeployPCEGovernorV2.s.sol/DeployPCEGovernorV2.json")
            );
            v2 = IPCEGovernorV2(governorDeployment.run());
        }
        PIP23DeploymentChecks checks =
            PIP23DeploymentChecks(deployCode("PIP23DeploymentChecks.sol:PIP23DeploymentChecks"));
        checks.validate(address(newToken), address(v2));
    }

    function _generateProposal(string memory sampleName) internal returns (string memory json) {
        string[] memory command = new string[](10);
        command[0] = "python3";
        command[1] = "script/generate_pip23_proposal.py";
        command[2] = "--csv";
        command[3] = vm.envOr("PIP23_CSV_PATH", string("test/fixtures/distribution_25904711.csv"));
        command[4] = "--new-pce";
        command[5] = vm.toString(address(newToken));
        command[6] = "--governor-v2";
        command[7] = vm.toString(address(v2));
        command[8] = "--description";
        command[9] = migrationDescription;
        json = string(vm.ffi(command));
        vm.createDir("out/pip23", true);
        string memory outputPath = string.concat("out/pip23/fork-", sampleName, ".json");
        vm.writeJson(json, outputPath);
        console2.log("Generated proposal JSON", outputPath);
    }

    function _runMigration(bool delegateAll, string memory sampleName) internal {
        (address[] memory r, uint256[] memory a) = PIP23Distribution.table();
        // Exercise both the normal case and the high-gas case of every recipient delegating early.
        if (delegateAll) {
            for (uint256 i; i < r.length; ++i) {
                vm.prank(r[i]);
                newToken.delegate(r[i]);
            }
        } else {
            vm.prank(voters[0]);
            newToken.delegate(voters[0]);
        }
        string memory proposal = _generateProposal(sampleName);
        address[] memory targets = vm.parseJsonAddressArray(proposal, ".targets");
        uint256[] memory values = vm.parseJsonUintArray(proposal, ".values");
        bytes[] memory calls = vm.parseJsonBytesArray(proposal, ".calldatas");
        string memory description = vm.parseJsonString(proposal, ".description");
        bytes32 descriptionHash = vm.parseJsonBytes32(proposal, ".descriptionHash");
        uint256 expectedId = uint256(vm.parseJsonBytes32(proposal, ".proposalIdHex"));
        assertEq(descriptionHash, keccak256(bytes(description)));
        assertEq(governor.hashProposal(targets, values, calls, descriptionHash), expectedId);
        assertEq(
            vm.parseJsonBytes(proposal, ".proposeCalldata"),
            abi.encodeCall(IGovernor.propose, (targets, values, calls, description))
        );
        assertEq(targets[0], address(newToken));
        assertEq(targets[1], GOVERNOR);
        assertEq(calls[0], abi.encodeCall(PCEMainnetToken.distribute, (r, a)));
        assertEq(
            calls[1],
            abi.encodeWithSignature(
                "upgradeToAndCall(address,bytes)",
                address(v2),
                abi.encodeCall(IPCEGovernorV2.switchVotingToken, (IVotes(address(newToken))))
            )
        );
        uint256 id = _queue(targets, values, calls, description);
        assertEq(id, expectedId);
        console2.log("New PCE proxy", address(newToken));
        console2.log("Governor V2 implementation", address(v2));
        console2.log("Proposal ID", id);
        bytes32[5] memory beforeSlots;
        for (uint256 i; i < 5; ++i) {
            beforeSlots[i] = vm.load(GOVERNOR, bytes32(i));
        }
        uint256 legacySupply = IERC20(LEGACY_PCE).totalSupply();
        uint256 wrappedSupply = IERC20(WPCE).totalSupply();
        uint256 wrappedBacking = IERC20(LEGACY_PCE).balanceOf(WPCE);
        vm.warp(governor.proposalEta(id));

        // Clear accesses made by setup/queue to measure a cold execution call, not a warm one.
        address tokenImpl = address(uint160(uint256(vm.load(address(newToken), IMPLEMENTATION_SLOT))));
        vm.cool(GOVERNOR);
        vm.cool(EXPECTED_IMPLEMENTATION);
        vm.cool(TIMELOCK);
        vm.cool(address(newToken));
        vm.cool(tokenImpl);
        vm.cool(address(v2));
        bytes memory execution = abi.encodeCall(IGovernor.execute, (targets, values, calls, descriptionHash));
        uint256 intrinsicGas = 21_000;
        for (uint256 i; i < execution.length; ++i) {
            intrinsicGas += execution[i] == 0 ? 4 : 16;
        }
        vm.recordLogs();
        governor.execute(targets, values, calls, descriptionHash);
        uint256 executionGas = vm.lastCallGas().gasTotalUsed;
        console2.log("Migration cold execute call gas (before refunds)", executionGas);
        console2.log("Migration intrinsic calldata gas", intrinsicGas);
        console2.log("Migration total gas upper bound (call + intrinsic, before refunds)", executionGas + intrinsicGas);
        assertLt(executionGas + intrinsicGas, 16_777_216);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 distributed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(newToken) && logs[i].topics[0] == keccak256("Distributed(address,uint256)"))
            {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), r[distributed]);
                assertEq(abi.decode(logs[i].data, (uint256)), a[distributed]);
                ++distributed;
            }
        }
        assertEq(distributed, 138);
        assertEq(newToken.totalSupply(), EXPECTED_SUPPLY);
        for (uint256 i; i < r.length; ++i) {
            assertEq(newToken.balanceOf(r[i]), a[i]);
            assertEq(newToken.getVotes(r[i]), delegateAll || r[i] == voters[0] ? a[i] : 0);
        }
        assertEq(newToken.balanceOf(WPCE), 0);
        assertEq(newToken.balanceOf(address(bytes20(hex"56a62dd43f135bad525df9179b0ef4fad5639ca1"))), 0);
        assertEq(newToken.balanceOf(address(bytes20(hex"3ce03c46a5de51e7ea690eec54c0eaf0d8028323"))), 0);
        assertEq(address(governor.token()), address(newToken));
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Executed));
        assertFalse(newToken.distributionClosed());
        _assertRules();
        for (uint256 i; i < 5; ++i) {
            assertEq(vm.load(GOVERNOR, bytes32(i)), beforeSlots[i]);
        }
        assertEq(IERC20(LEGACY_PCE).totalSupply(), legacySupply);
        assertEq(IERC20(WPCE).totalSupply(), wrappedSupply);
        assertEq(IERC20(LEGACY_PCE).balanceOf(WPCE), wrappedBacking);
    }
}

contract PIP23PredelegatedForkTest is PIP23ForkBaseTest {
    function testForkAllRecipientsPredelegatedFitsGasLimit() public {
        _runMigration(true, "predelegated");
    }
}

contract PIP23ForkTest is PIP23ForkBaseTest {
    function testForkMigrationAndNewPCEGovernance() public {
        _runMigration(false, "migration");
        uint256 votes;
        for (uint256 i; i < voters.length; ++i) {
            vm.prank(voters[i]);
            newToken.delegate(voters[i]);
            votes += newToken.getVotes(voters[i]);
        }
        assertGt(votes, 500_000 ether);
        vm.roll(block.number + 1);
        (address[] memory targets, uint256[] memory values, bytes[] memory calls) =
            _oneAction(address(newToken), abi.encodeCall(PCEMainnetToken.closeDistribution, ()));
        uint256 id = _queue(targets, values, calls, "Post-PIP-23 fork proposal");
        vm.warp(governor.proposalEta(id));
        governor.execute(targets, values, calls, keccak256("Post-PIP-23 fork proposal"));
        assertTrue(newToken.distributionClosed());
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Executed));
    }
}

contract PIP23QueuedForkTest is PIP23ForkBaseTest {
    function testForkPreviouslyQueuedProposalStillExecutable() public {
        // Separate regression scenario: the actual migration should have no other open proposals.
        PIP23Target target = new PIP23Target();
        (address[] memory targets, uint256[] memory values, bytes[] memory calls) =
            _oneAction(address(target), abi.encodeCall(PIP23Target.setValue, (23)));
        uint256 id = _queue(targets, values, calls, "Pre-PIP-23 queued proposal");
        _runMigration(false, "queued");
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Queued));
        if (block.timestamp < governor.proposalEta(id)) vm.warp(governor.proposalEta(id));
        governor.execute(targets, values, calls, keccak256("Pre-PIP-23 queued proposal"));
        assertEq(target.value(), 23);
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Executed));
    }
}

contract PIP23TimelockRolesForkTest is PIP23ForkBaseTest {
    function testForkTimelockRolePrerequisitesForKnownAccounts() public view {
        // hasRole cannot enumerate holders. Exhaustive role-event auditing remains a deployment prerequisite.
        address[11] memory accounts = [
            GOVERNOR,
            TIMELOCK,
            address(0),
            WPCE,
            LEGACY_PCE,
            EXPECTED_IMPLEMENTATION,
            voters[0],
            voters[1],
            voters[2],
            address(this),
            0xBeB4C556E8f24aF598f9BDc3f9B5BADB3F08aeEf
        ];
        bytes32 proposer = timelock.PROPOSER_ROLE();
        bytes32 canceller = timelock.CANCELLER_ROLE();
        bytes32 admin = timelock.DEFAULT_ADMIN_ROLE();
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            assertEq(timelock.hasRole(proposer, account), account == GOVERNOR || account == address(0), "PROPOSER_ROLE");
            assertEq(timelock.hasRole(canceller, account), account == address(0), "CANCELLER_ROLE");
            assertEq(timelock.hasRole(admin, account), account == TIMELOCK, "DEFAULT_ADMIN_ROLE");
        }
    }
}

/// @dev Exercise the existing-address branch with valid deployments on the local fork.
/// No shared process environment is mutated; actual mainnet addresses can use the three PIP23_* inputs.
contract PIP23ExistingDeploymentsForkTest is PIP23ForkBaseTest {
    function testForkReusesExistingDeploymentsAndExactDescription() public {
        address proxy = address(newToken);
        address implementation = address(v2);
        bytes32 tokenCodeHash = proxy.codehash;
        bytes32 implementationCodeHash = implementation.codehash;
        string memory description = vm.envExists("PIP23_DESCRIPTION")
            ? migrationDescription
            : "PIP-23 production input fixture with trailing whitespace \n";
        _selectDeployments(true, proxy, implementation, description);
        assertEq(address(newToken), proxy);
        assertEq(address(v2), implementation);
        assertEq(proxy.codehash, tokenCodeHash);
        assertEq(implementation.codehash, implementationCodeHash);
        assertEq(migrationDescription, description);
        _runMigration(false, "existing-fixture");
    }
}
