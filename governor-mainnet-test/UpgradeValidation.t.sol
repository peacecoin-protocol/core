// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { Upgrades, Options } from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract MainnetGovernorUpgradeValidationTest is Test {
    function testValidateUpgradeAgainstVerifiedProductionImplementation() public {
        // The library otherwise assumes the default "out" directory rather than the profile's out.
        vm.setEnv("FOUNDRY_OUT", "out-governor-mainnet");
        Options memory opts;
        Upgrades.validateUpgrade("PCEGovernorV2.sol:PCEGovernorV2", opts);
    }
}
