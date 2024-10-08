// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "../Bounty.sol";

contract BountyScript is Script {
    function run() external {
        address pceToken = 0xf939595726798393F63Dbe098a54C7948DEF8faF;
        address governance = 0xb21473F6103f79991546D44C1417362fF7873b90;
        uint256 _bountyAmount = 10e18;

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        Bounty bounty = new Bounty();
        bounty.initialize(
            ERC20Upgradeable(pceToken),
            _bountyAmount,
            governance
        );
        vm.stopBroadcast();
    }
}
