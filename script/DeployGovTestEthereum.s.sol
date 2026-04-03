// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Wrapper} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorVotesQuorumFraction} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GovernanceSender} from "../src/governance/GovernanceSender.sol";

contract TestPCE is ERC20 {
    constructor(uint256 initialSupply) ERC20("Test PCE", "TPCE") { _mint(msg.sender, initialSupply); }
}

contract TestWPCE is ERC20, ERC20Permit, ERC20Votes, ERC20Wrapper {
    constructor(IERC20 _underlying) ERC20("Test Wrapped PCE", "TWPCE") ERC20Permit("Test Wrapped PCE") ERC20Wrapper(_underlying) {}
    function decimals() public view override(ERC20, ERC20Wrapper) returns (uint8) { return super.decimals(); }
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) { super._update(from, to, value); }
    function nonces(address o) public view override(ERC20Permit, Nonces) returns (uint256) { return super.nonces(o); }
}

contract TestGovernor is Governor, GovernorSettings, GovernorCountingSimple, GovernorVotes, GovernorVotesQuorumFraction, GovernorTimelockControl {
    constructor(IVotes _token, TimelockController _timelock)
        Governor("Test PCE Governor") GovernorSettings(1, 10, 0) GovernorVotes(_token) GovernorVotesQuorumFraction(1) GovernorTimelockControl(_timelock) {}
    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) { return super.votingDelay(); }
    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) { return super.votingPeriod(); }
    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) { return super.proposalThreshold(); }
    function quorum(uint256 bn) public view override(Governor, GovernorVotesQuorumFraction) returns (uint256) { return super.quorum(bn); }
    function state(uint256 id) public view override(Governor, GovernorTimelockControl) returns (ProposalState) { return super.state(id); }
    function proposalNeedsQueuing(uint256 id) public view override(Governor, GovernorTimelockControl) returns (bool) { return super.proposalNeedsQueuing(id); }
    function _queueOperations(uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) internal override(Governor, GovernorTimelockControl) returns (uint48) { return super._queueOperations(id, t, v, c, h); }
    function _executeOperations(uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) internal override(Governor, GovernorTimelockControl) { super._executeOperations(id, t, v, c, h); }
    function _cancel(address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) internal override(Governor, GovernorTimelockControl) returns (uint256) { return super._cancel(t, v, c, h); }
    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) { return super._executor(); }
}

/**
 * @title DeployGovTestEthereum
 * @notice Deploy a complete test governance stack on Ethereum for E2E testing
 *
 * Usage:
 * source .env && GOVERNANCE_RECEIVER=<polygon_receiver> \
 *   forge script script/DeployGovTestEthereum.s.sol --tc DeployGovTestEthereum --rpc-url mainnet --broadcast
 */
contract DeployGovTestEthereum is Script {
    address public constant WORMHOLE_CORE_ETHEREUM = 0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B;
    uint256 public constant TIMELOCK_DELAY = 60;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address governanceReceiver = vm.envAddress("GOVERNANCE_RECEIVER");

        vm.startBroadcast(deployerPrivateKey);

        TestPCE pce = new TestPCE(1_000_000 ether);
        TestWPCE wpce = new TestWPCE(IERC20(address(pce)));
        pce.approve(address(wpce), 1_000_000 ether);
        wpce.depositFor(deployer, 1_000_000 ether);
        wpce.delegate(deployer);

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, deployer);

        TestGovernor governor = new TestGovernor(IVotes(address(wpce)), timelock);
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);

        GovernanceSender sender = new GovernanceSender(WORMHOLE_CORE_ETHEREUM, governanceReceiver, address(timelock));

        vm.stopBroadcast();

        console.log("\n=== GovTest Ethereum Stack Deployed ===");
        console.log("TestPCE:", address(pce));
        console.log("TestWPCE:", address(wpce));
        console.log("TestTimelock (60s):", address(timelock));
        console.log("TestGovernor:", address(governor));
        console.log("TestGovernanceSender:", address(sender));
        console.log("GovernanceReceiver (Polygon):", governanceReceiver);
    }
}
