// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

contract TimelockAuthorizationTest is Test {
    function testZeroAddressProposerDoesNotAuthorizeOtherAccounts() public {
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        // Mirrors the existing bootstrap. Open execution does not imply open scheduling.
        TimelockController timelock = new TimelockController(1 days, proposers, executors, address(this));
        address caller = address(0xCAFE);
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, proposerRole)
        );
        timelock.scheduleBatch(new address[](0), new uint256[](0), new bytes[](0), bytes32(0), bytes32(0), 1 days);
    }
}
