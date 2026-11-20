// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { PCEMainnetToken } from "../../src/PCEMainnetToken.sol";

/// @dev Read-only checks against locally built artifacts, not Etherscan verification or an event-history audit.
contract PIP23DeploymentChecks is Test {
    bytes32 private constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    address private constant TIMELOCK = 0x208983f723245C765b4F9E57FAaB2633c9DDaC6B;
    address private constant OLD_IMPL = address(bytes20(hex"911c1f527651374ba6546b1f1510832084af5208"));

    struct ImmutableReference {
        uint256 length;
        uint256 start;
    }

    function validate(address proxy, address governorV2) external view {
        require(block.chainid == 1, "PIP-23: Ethereum mainnet only");
        require(proxy != governorV2 && governorV2 != OLD_IMPL, "PIP-23: wrong deployment addresses");
        _runtime(proxy, "out/ERC1967Proxy.sol/ERC1967Proxy.json", false);
        require(vm.load(proxy, ADMIN_SLOT) == bytes32(0), "PIP-23: nonzero proxy admin");
        bytes32 implementation = vm.load(proxy, IMPL_SLOT);
        address impl = address(uint160(uint256(implementation)));
        require(
            implementation == bytes32(uint256(uint160(impl))) && impl != address(0),
            "PIP-23: invalid implementation slot"
        );
        _runtime(impl, "out/PCEMainnetToken.sol/PCEMainnetToken.json", true);
        PCEMainnetToken token = PCEMainnetToken(proxy);
        require(token.owner() == TIMELOCK, "PIP-23: wrong token owner");
        require(token.totalSupply() == 0, "PIP-23: nonzero token supply");
        require(!token.distributionClosed(), "PIP-23: distribution closed");
        _runtime(governorV2, "out-governor-mainnet/PCEGovernorV2.sol/PCEGovernorV2.json", true);
    }

    function _runtime(address target, string memory artifact, bool uups) private view {
        require(vm.exists(artifact), "PIP-23: missing artifact; run FORGE=/path/to/forge-1.7.1 npm run build:pip23");
        string memory json = vm.readFile(artifact);
        bytes memory expected = vm.parseJsonBytes(json, ".deployedBytecode.object");
        if (uups) {
            string memory base = ".deployedBytecode.immutableReferences";
            string[] memory keys = vm.parseJsonKeys(json, base);
            require(keys.length == 1, "PIP-23: expected only UUPS __self immutable");
            ImmutableReference[] memory refs =
                abi.decode(vm.parseJson(json, string.concat(base, "['", keys[0], "']")), (ImmutableReference[]));
            require(refs.length > 0, "PIP-23: missing UUPS immutable references");
            bytes32 self = bytes32(uint256(uint160(target)));
            for (uint256 i; i < refs.length; ++i) {
                require(
                    refs[i].length == 32 && refs[i].start + 32 <= expected.length, "PIP-23: invalid immutable reference"
                );
                for (uint256 j; j < 32; ++j) {
                    require(expected[refs[i].start + j] == 0, "PIP-23: expected immutable placeholder");
                    expected[refs[i].start + j] = self[j];
                }
            }
        }
        require(
            target.code.length > 0 && keccak256(target.code) == keccak256(expected),
            string.concat("PIP-23: runtime mismatch for ", artifact)
        );
    }
}
