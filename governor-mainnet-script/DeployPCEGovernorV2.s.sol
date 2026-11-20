// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Build: FORGE=/path/to/forge-1.7.1 npm run build:governor-mainnet
// Dry run (no keys, no broadcast):
//   FOUNDRY_PROFILE=governor_mainnet "$FORGE" script \
//     governor-mainnet-script/DeployPCEGovernorV2.s.sol:DeployPCEGovernorV2 \
//     --rpc-url https://ethereum-rpc.publicnode.com --sender <DEPLOYER_ADDRESS>
// Deploys only the OZ 5.0.2 / solc 0.8.26 implementation. It does NOT upgrade the Governor.
// The upgrade and switchVotingToken must be executed together in the DAO proposal.
// Actual broadcast requires separate approval and CLI wallet configuration; no secrets are read here.

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { PCEGovernorV2 } from "../governor-mainnet/PCEGovernorV2.sol";

contract DeployPCEGovernorV2 is Script {
    function run() external returns (address implementation) {
        require(block.chainid == 1, "PIP-23: Ethereum mainnet only");
        vm.startBroadcast();
        PCEGovernorV2 deployed = new PCEGovernorV2();
        vm.stopBroadcast();
        implementation = address(deployed);
        assert(implementation.code.length <= 24_576);
        assert(deployed.proxiableUUID() == 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        console.log("PCEGovernorV2 implementation (not upgraded):", implementation);
    }
}
