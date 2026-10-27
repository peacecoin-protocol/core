// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { ShopVaultFactory } from "../src/shop/ShopVaultFactory.sol";

/**
 * Deploys ShopVaultFactory with owner = PUBLIC_KEY.
 *   source .env && forge script script/ShopVaultDeploy.s.sol --rpc-url polygon --broadcast
 */
contract ShopVaultDeploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("PUBLIC_KEY");
        vm.startBroadcast(deployerPrivateKey);
        ShopVaultFactory factory = new ShopVaultFactory(owner);
        vm.stopBroadcast();
        console.log("ShopVaultFactory:", address(factory));
        console.log("implementation:", factory.implementation());
        console.logBytes32(factory.initCodeHash());
    }
}
