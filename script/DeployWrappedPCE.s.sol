// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { WrappedPCEToken } from "../src/WrappedPCEToken.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployWrappedPCE
 * @notice Deployment script for Wrapped PeaceCoin Token (WPCE)
 *
 * Required environment variables:
 * - PCE_TOKEN_ADDRESS: Address of the PeaceCoin token to wrap
 * - PRIVATE_KEY: Private key of the deployer (will be the owner)
 *
 * Usage:
 * forge script script/DeployWrappedPCE.s.sol --rpc-url <RPC_URL> --broadcast
 */
contract DeployWrappedPCE is Script {
    function run() external returns (address wpce, address implementation) {
        address pceTokenAddress = vm.envAddress("PCE_TOKEN_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        string memory symbol = vm.envOr("WPCE_SYMBOL", string("WPCE"));
        address owner = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        implementation = address(new WrappedPCEToken());
        console.log("WrappedPCEToken implementation deployed at:", implementation);

        bytes memory initData = abi.encodeWithSelector(
            WrappedPCEToken.initialize.selector,
            "Wrapped PeaceCoin Token",
            symbol,
            pceTokenAddress,
            owner
        );
        wpce = address(new ERC1967Proxy(implementation, initData));
        console.log("WPCE deployed at:", wpce);

        vm.stopBroadcast();

        WrappedPCEToken wpceContract = WrappedPCEToken(wpce);

        console.log("\nDeployment Summary:");
        console.log("===================");
        console.log("Implementation:", implementation);
        console.log("\nWPCE (Wrapped PeaceCoin Token):");
        console.log("  Address:", wpce);
        console.log("  Name:", wpceContract.name());
        console.log("  Symbol:", wpceContract.symbol());
        console.log("  PCE Token:", address(wpceContract.pceToken()));
        console.log("  Owner:", wpceContract.owner());
    }
}

