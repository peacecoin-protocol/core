// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Build: FORGE=/path/to/forge-1.7.1 npm run build:pip23
// Dry run (no keys, no broadcast):
//   "$FORGE" script script/DeployPCEMainnetToken.s.sol:DeployPCEMainnetToken \
//     --rpc-url https://ethereum-rpc.publicnode.com --sender <DEPLOYER_ADDRESS>
// Outputs implementation, proxy and deployment-receipt addresses. The one broadcastable CREATE
// creates a receipt whose constructor deploys both implementation and initialized ERC1967Proxy.
// Actual broadcast/verification requires separate approval and CLI wallet configuration.
// Unlike BaseScript, this script never reads MNEMONIC, PRIVATE_KEY or .env itself.

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { PCEMainnetToken } from "../src/PCEMainnetToken.sol";

/// @dev Immutable deployment receipt; no roles, setters, upgrade powers or callable deployment methods.
contract PCEMainnetTokenDeployment {
    address public constant TIMELOCK = 0x208983f723245C765b4F9E57FAaB2633c9DDaC6B;
    address public immutable implementation;
    address public immutable proxy;

    constructor() {
        require(block.chainid == 1, "PIP-23: Ethereum mainnet only");
        implementation = address(new PCEMainnetToken());
        proxy = address(new ERC1967Proxy(implementation, abi.encodeCall(PCEMainnetToken.initialize, (TIMELOCK))));
        PCEMainnetToken token = PCEMainnetToken(proxy);
        require(token.owner() == TIMELOCK, "PIP-23: wrong owner");
        require(token.totalSupply() == 0, "PIP-23: nonzero initial supply");
        require(!token.distributionClosed(), "PIP-23: distribution already closed");
    }
}

contract DeployPCEMainnetToken is Script {
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function run() external returns (address implementation, address proxy, address receipt) {
        require(block.chainid == 1, "PIP-23: Ethereum mainnet only");
        vm.startBroadcast();
        PCEMainnetTokenDeployment deployment = new PCEMainnetTokenDeployment();
        vm.stopBroadcast();

        receipt = address(deployment);
        implementation = deployment.implementation();
        proxy = deployment.proxy();
        PCEMainnetToken token = PCEMainnetToken(proxy);
        assert(token.owner() == deployment.TIMELOCK());
        assert(token.totalSupply() == 0);
        assert(!token.distributionClosed());
        assert(vm.load(proxy, ADMIN_SLOT) == bytes32(0));
        assert(vm.load(proxy, IMPLEMENTATION_SLOT) == bytes32(uint256(uint160(implementation))));
        assert(implementation.code.length <= 24_576);
        console.log("PCEMainnetToken implementation:", implementation);
        console.log("PCEMainnetToken proxy:", proxy);
        console.log("Atomic deployment receipt (no privileges):", receipt);
    }
}
