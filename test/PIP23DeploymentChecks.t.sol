// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { PIP23ArtifactHelper } from "./fixtures/PIP23ArtifactHelper.sol";
import { PIP23DeploymentChecks } from "./fixtures/PIP23DeploymentChecks.sol";
import { DeployPCEMainnetToken } from "../script/DeployPCEMainnetToken.s.sol";
import { PCEMainnetToken } from "../src/PCEMainnetToken.sol";

contract PIP23DeploymentChecksTest is PIP23ArtifactHelper {
    address private constant TIMELOCK = 0x208983f723245C765b4F9E57FAaB2633c9DDaC6B;
    bytes32 private constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    PIP23DeploymentChecks private checks;
    PCEMainnetToken private token;
    address private impl;
    address private v2;

    function setUp() public {
        vm.chainId(1);
        checks = PIP23DeploymentChecks(deployCode("PIP23DeploymentChecks.sol:PIP23DeploymentChecks"));
        DeployPCEMainnetToken script =
            DeployPCEMainnetToken(deployCode("DeployPCEMainnetToken.s.sol:DeployPCEMainnetToken"));
        address proxy;
        (impl, proxy,) = script.run();
        token = PCEMainnetToken(proxy);
        v2 = _deployGovernorArtifact("out-governor-mainnet/PCEGovernorV2.sol/PCEGovernorV2.json");
    }

    function testValidExistingDeployments() public view {
        checks.validate(address(token), v2);
    }

    function testRejectsSwappedAddresses() public {
        vm.expectRevert();
        checks.validate(v2, address(token));
    }

    function testRejectsTokenImplementationInsteadOfProxy() public {
        vm.expectRevert();
        checks.validate(impl, v2);
    }

    function testRejectsOldGovernor() public {
        address old = _deployGovernorArtifact("out-governor-mainnet/PCEGovernor.sol/PCEGovernor.json");
        vm.expectRevert();
        checks.validate(address(token), old);
    }

    function testRejectsWrongOwner() public {
        vm.prank(TIMELOCK);
        token.transferOwnership(address(this));
        vm.expectRevert("PIP-23: wrong token owner");
        checks.validate(address(token), v2);
    }

    function testRejectsNonzeroSupply() public {
        address[] memory r = new address[](1);
        uint256[] memory a = new uint256[](1);
        r[0] = address(this);
        a[0] = 1;
        vm.prank(TIMELOCK);
        token.distribute(r, a);
        vm.expectRevert("PIP-23: nonzero token supply");
        checks.validate(address(token), v2);
    }

    function testRejectsClosedDistribution() public {
        vm.prank(TIMELOCK);
        token.closeDistribution();
        vm.expectRevert("PIP-23: distribution closed");
        checks.validate(address(token), v2);
    }

    function testRejectsNonzeroAdmin() public {
        vm.store(address(token), ADMIN_SLOT, bytes32(uint256(1)));
        vm.expectRevert("PIP-23: nonzero proxy admin");
        checks.validate(address(token), v2);
    }

    function testRejectsWrongTokenImplementation() public {
        vm.store(address(token), IMPL_SLOT, bytes32(uint256(uint160(v2))));
        vm.expectRevert();
        checks.validate(address(token), v2);
    }

    function testRejectsIncorrectUUPSSelf() public {
        address other = makeAddr("copied implementation");
        vm.etch(other, v2.code);
        vm.expectRevert();
        checks.validate(address(token), other);
    }
}
