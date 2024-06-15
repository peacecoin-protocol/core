import { expect } from "chai";
import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";
import { BigNumber } from "ethers";
import { ethers } from "hardhat";

import { PCECommunityToken } from "../../types/contracts/PCECommunityToken";
import { PCEToken } from "../../types/contracts/PCEToken";

const ExchangeAllowMethod = {
  None: 0,
  Include: 1,
  Exclude: 2,
  All: 3,
};

dayjs.extend(utc);

describe("PCEToken contract", function () {
  let pceCommunityToken: PCECommunityToken;
  let pceToken: PCEToken;

  beforeEach(async function () {
    const PCECommunityToken = await ethers.getContractFactory("PCECommunityToken");
    pceCommunityToken = (await PCECommunityToken.deploy()) as PCECommunityToken;
    await pceCommunityToken.deployed();
    await pceCommunityToken.initialize("PCE Community Token", "PCEB", BigNumber.from(10).pow(35));
    await pceCommunityToken.setTokenSettings(
      1,
      1,
      1,
      1,
      1,
      1,
      ExchangeAllowMethod.All,
      ExchangeAllowMethod.All,
      [],
      [],
    );

    const PCEToken = await ethers.getContractFactory("PCEToken");
    pceToken = (await PCEToken.deploy()) as PCEToken;
    await pceToken.deployed();
    await pceToken.initialize(
      "PCE Token",
      "PCE",
      pceCommunityToken.address,
      "0x0000000000000000000000000000000000000000",
    );
  });

  it("Deployment should assign the total supply of tokens to the owner", async function () {
    const [owner] = await ethers.getSigners();

    const ownerBalance = await pceToken.balanceOf(owner.address);
    expect(await pceToken.totalSupply()).to.equal(ownerBalance);
  });

  it("isWednesdayBetween", async function () {
    const wednesdayStart = dayjs.utc("2029-06-06 00:00:00").unix();
    const nextWednesdayStart = dayjs.utc("2029-06-13 00:00:00").unix();

    expect(await pceToken.isWednesdayBetween(wednesdayStart - 2, wednesdayStart - 1)).to.equal(false, "-2 to -1");

    expect(await pceToken.isWednesdayBetween(wednesdayStart - 1, wednesdayStart)).to.equal(true, "-1 to 0");

    expect(await pceToken.isWednesdayBetween(wednesdayStart, wednesdayStart)).to.equal(false, "0 to 0");

    expect(await pceToken.isWednesdayBetween(wednesdayStart, wednesdayStart + 1)).to.equal(false, "0 to 1");

    expect(await pceToken.isWednesdayBetween(wednesdayStart, nextWednesdayStart - 1)).to.equal(false, "0 to next -1");

    expect(await pceToken.isWednesdayBetween(wednesdayStart, nextWednesdayStart)).to.equal(true, "0 to next 0");

    expect(await pceToken.isWednesdayBetween(wednesdayStart + 1, nextWednesdayStart)).to.equal(true, "1 to next 0");
  });
});
