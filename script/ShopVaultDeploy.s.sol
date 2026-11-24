// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { ShopVaultFactory } from "../src/shop/ShopVaultFactory.sol";

/**
 * Deploys ShopVaultFactory with owner = PUBLIC_KEY and, when SHOP_REFUND_RELAYER is set, the refund relayer
 * (the web app's relayer address; refunds signed by members other than the group owner go through it).
 *   source .env && forge script script/ShopVaultDeploy.s.sol --rpc-url polygon --broadcast
 */
contract ShopVaultDeploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("PUBLIC_KEY");
        vm.startBroadcast(deployerPrivateKey);
        ShopVaultFactory factory = new ShopVaultFactory(owner);
        address refundRelayer = vm.envOr("SHOP_REFUND_RELAYER", address(0));
        if (refundRelayer != address(0) && owner == vm.addr(deployerPrivateKey)) {
            factory.setRefundRelayer(refundRelayer);
        }
        vm.stopBroadcast();
        console.log("ShopVaultFactory:", address(factory));
        console.log("implementation:", factory.implementation());
        console.logBytes32(factory.initCodeHash());
        console.log("refundRelayer:", factory.refundRelayer());
    }
}
