// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { PeaceCoinTokenDev } from "../src/PeaceCoinTokenDev.sol";

contract DeployPeaceCoinTokenDev is Script {
    function run() external returns (PeaceCoinTokenDev) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);
        uint256 mintAmount = 1000000 * 10**18;

        vm.startBroadcast(deployerPrivateKey);

        PeaceCoinTokenDev token = new PeaceCoinTokenDev(
            "Peace Coin Token Dev",
            "DPCE"
        );

        token.mint(deployerAddress, mintAmount);

        vm.stopBroadcast();

        return token;
    }
}
