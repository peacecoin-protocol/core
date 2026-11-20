// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

abstract contract PIP23ArtifactHelper is Test {
    function _deployGovernorArtifact(string memory artifact) internal returns (address) {
        require(
            vm.exists(artifact),
            string.concat(
                "Missing governor_mainnet artifact: ",
                artifact,
                ". Run FORGE=/path/to/forge-1.7.1 npm run build:pip23 before direct forge test."
            )
        );
        return deployCode(artifact);
    }
}
