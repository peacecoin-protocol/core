import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { task } from "hardhat/config";
import type { TaskArguments } from "hardhat/types";

import type { PCECommunityToken } from "../../types/contracts/PCECommunityToken";
import type { PCEToken } from "../../types/contracts/PCEToken";
import type { PCECommunityToken__factory } from "../../types/factories/contracts/PCECommunityToken__factory";
import type { PCEToken__factory } from "../../types/factories/contracts/PCEToken__factory";

task("deploy:PCEToken").setAction(async function (taskArguments: TaskArguments, { ethers }) {
  const signers: SignerWithAddress[] = await ethers.getSigners();

  const pcebasetokenFactory: PCECommunityToken__factory = <PCECommunityToken__factory>(
    await ethers.getContractFactory("PCECommunityToken")
  );
  const pcebasetoken: PCECommunityToken = <PCECommunityToken>await pcebasetokenFactory.connect(signers[0]).deploy();

  const pcetokenFactory: PCEToken__factory = <PCEToken__factory>await ethers.getContractFactory("PCEToken");
  const pcetoken: PCEToken = <PCEToken>await pcetokenFactory.connect(signers[0]).deploy();
  // mainnet: https://github.com/maticnetwork/static/blob/master/network/mainnet/v1/index.json
  //await pcetoken.initialize("PCE Token", "PCE", pcebasetoken.address, "0xa40fc0782bee28dd2cf8cb4ac2ecdb05c537f1b5");
  // amoy: https://github.com/maticnetwork/static/blob/master/network/testnet/amoy/index.json
  await pcetoken.initialize("PCE Token", "PCE", pcebasetoken.address, "0x687C1D2dd0F422421BeF7aC2a52f50e858CAA867");

  console.log("PCECommunityToken deployed to: ", pcebasetoken.address);
  console.log("PCEToken deployed to: ", pcetoken.address);
});
