import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { task } from "hardhat/config";
import type { TaskArguments } from "hardhat/types";

import type { ETHPCEToken } from "../../types/contracts/ETHPCEToken";
import type { ETHPCEToken__factory } from "../../types/factories/contracts/ETHPCEToken__factory";

task("deploy:ETHPCEToken").setAction(async function (taskArguments: TaskArguments, { ethers }) {
  const signers: SignerWithAddress[] = await ethers.getSigners();

  const pcetokenFactory: ETHPCEToken__factory = <ETHPCEToken__factory>await ethers.getContractFactory("ETHPCEToken");
  const pcetoken: ETHPCEToken = <ETHPCEToken>await pcetokenFactory.connect(signers[0]).deploy();
  await pcetoken.initialize("PCE Token", "PCE", ethers.utils.parseUnits("10000000", 18));

  console.log("ETHPCEToken deployed to: ", pcetoken.address);
});
