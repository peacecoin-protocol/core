// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "../Governance/GovernorAlpha.sol";
import "../Governance/Timelock.sol";

contract DAOScript is Script {
    function run() external {
        address pceToken = 0xf939595726798393F63Dbe098a54C7948DEF8faF;
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address deployerAddress = vm.addr(deployerPrivateKey);

        Timelock timelock = new Timelock(deployerAddress, 10 minutes);
        GovernorAlpha governance = new GovernorAlpha(
            address(timelock),
            pceToken,
            deployerAddress
        );

        timelock.setPendingAdmin(address(governance));

        vm.stopBroadcast();
    }
}
