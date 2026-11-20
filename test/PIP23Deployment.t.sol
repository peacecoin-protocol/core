// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Test.sol";
import { PIP23ArtifactHelper } from "./fixtures/PIP23ArtifactHelper.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { DeployPCEMainnetToken, PCEMainnetTokenDeployment } from "../script/DeployPCEMainnetToken.s.sol";
import { PCEMainnetToken } from "../src/PCEMainnetToken.sol";
import { IPCEGovernorV2 } from "./fixtures/IPCEGovernorV2.sol";

interface IPIP23DeployGovernor {
    function run() external returns (address implementation);
}

contract PIP23DeploymentTest is PIP23ArtifactHelper {
    address private constant TIMELOCK = 0x208983f723245C765b4F9E57FAaB2633c9DDaC6B;
    bytes32 private constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function setUp() public {
        vm.chainId(1);
    }

    function testTokenDeploymentIsAtomicInitializedAndHasNoDeployerPrivileges() public {
        DeployPCEMainnetToken script =
            DeployPCEMainnetToken(deployCode("DeployPCEMainnetToken.s.sol:DeployPCEMainnetToken"));
        vm.recordLogs();
        (address impl, address proxy, address receipt) = script.run();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        PCEMainnetToken token = PCEMainnetToken(proxy);
        assertEq(vm.getNonce(receipt), 3); // One constructor created both children; no callable deploy function exists.
        assertEq(vm.computeCreateAddress(receipt, 1), impl);
        assertEq(vm.computeCreateAddress(receipt, 2), proxy);
        assertEq(PCEMainnetTokenDeployment(receipt).implementation(), impl);
        assertEq(token.owner(), TIMELOCK);
        assertEq(token.totalSupply(), 0);
        assertFalse(token.distributionClosed());
        assertEq(vm.load(proxy, ADMIN_SLOT), bytes32(0));
        assertEq(vm.load(proxy, IMPL_SLOT), bytes32(uint256(uint160(impl))));
        uint256 upgrades;
        uint256 ownershipChanges;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != proxy) continue;
            if (logs[i].topics[0] == keccak256("Upgraded(address)")) {
                ++upgrades;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), impl);
            }
            if (logs[i].topics[0] == keccak256("OwnershipTransferred(address,address)")) {
                ++ownershipChanges;
                assertEq(logs[i].topics[1], bytes32(0));
                assertEq(address(uint160(uint256(logs[i].topics[2]))), TIMELOCK);
            }
        }
        assertEq(upgrades, 1);
        assertEq(ownershipChanges, 1);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize(address(this));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        PCEMainnetToken(impl).initialize(TIMELOCK);
        address[3] memory unauthorized = [address(this), address(script), receipt];
        for (uint256 i; i < unauthorized.length; ++i) {
            vm.prank(unauthorized[i]);
            vm.expectRevert(
                abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, unauthorized[i])
            );
            token.closeDistribution();
        }
    }

    function testGovernorScriptDeploysLockedImplementationOnly() public {
        IPIP23DeployGovernor script = IPIP23DeployGovernor(
            _deployGovernorArtifact("out-governor-mainnet/DeployPCEGovernorV2.s.sol/DeployPCEGovernorV2.json")
        );
        address impl = script.run();
        assertGt(impl.code.length, 0);
        assertLe(impl.code.length, 24_576);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        IPCEGovernorV2(impl).initialize("bad", address(1), TIMELOCK, 1, 1, 1, address(1), 1);
    }

    function testTokenScriptRejectsWrongChain() public {
        DeployPCEMainnetToken script =
            DeployPCEMainnetToken(deployCode("DeployPCEMainnetToken.s.sol:DeployPCEMainnetToken"));
        vm.chainId(137);
        vm.expectRevert("PIP-23: Ethereum mainnet only");
        script.run();
    }

    function testGovernorScriptRejectsWrongChain() public {
        IPIP23DeployGovernor script = IPIP23DeployGovernor(
            _deployGovernorArtifact("out-governor-mainnet/DeployPCEGovernorV2.s.sol/DeployPCEGovernorV2.json")
        );
        vm.chainId(137);
        vm.expectRevert("PIP-23: Ethereum mainnet only");
        script.run();
    }
}
