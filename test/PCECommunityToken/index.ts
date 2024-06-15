import { expect } from "chai";
import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";
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

describe("PCECommunityToken contract", function () {
  let pceCommunityToken: PCECommunityToken;
  let pceToken: PCEToken;

  beforeEach(async function () {
    const PCECommunityToken = await ethers.getContractFactory("PCECommunityToken");
    const basePceCommunityToken = (await PCECommunityToken.deploy()) as PCECommunityToken;
    await basePceCommunityToken.deployed();

    const PCEToken = await ethers.getContractFactory("PCEToken");
    pceToken = (await PCEToken.deploy()) as PCEToken;
    await pceToken.deployed();
    await pceToken.initialize(
      "PCE Token",
      "PCE",
      basePceCommunityToken.address,
      "0x0000000000000000000000000000000000000000",
    );

    const tx = await pceToken.createToken(
      "CommunityToken", // Name
      "CTP", // Symbol
      ethers.utils.parseEther("1000"), // amountToExchange
      ethers.utils.parseEther("1"), // dilutionFactor
      7, // decreaseIntervalDays
      20, // decreaseBp
      20, // maxIncreaseOfTotalSupplyBp
      2000, // maxIncreaseBp
      3000, // maxUsageBp
      3000, // changeBp
      ExchangeAllowMethod.All, // incomeAllowMethod
      ExchangeAllowMethod.All, // outgoAllowMethod
      [], // incomeTargetTokens
      [], // outgoTargetTokens
    );
    const rec = await tx.wait();
    let aTokenAddress;
    if (rec.events) {
      for (const event of rec.events) {
        if (event.event === "TokenCreated" && event.args) {
          aTokenAddress = event.args[0];
        }
      }
    }
    pceCommunityToken = (await ethers.getContractAt("PCECommunityToken", aTokenAddress)) as PCECommunityToken;
  });

  it("Deployment should assign the total supply of tokens to the owner", async function () {
    const [owner] = await ethers.getSigners();

    const ownerBalance = await pceCommunityToken.balanceOf(owner.address);
    expect(await pceCommunityToken.totalSupply()).to.equal(ownerBalance);
  });
  it("intervalDaysOf", async function () {
    const today = dayjs.utc("2029-06-06 00:00:00").unix();
    const tomorrow = dayjs.utc("2029-06-07 00:00:00").unix();
    const next2Day = dayjs.utc("2029-06-08 00:00:00").unix();
    expect(await pceCommunityToken.intervalDaysOf(today - 2, today - 1, 1)).to.equal(false, "-2 to -1");
    expect(await pceCommunityToken.intervalDaysOf(today - 1, today, 1)).to.equal(true, "-1 to 0");
    expect(await pceCommunityToken.intervalDaysOf(today, today, 1)).to.equal(false, "0 to 0");
    expect(await pceCommunityToken.intervalDaysOf(today, today + 1, 1)).to.equal(false, "0 to +1");
    expect(await pceCommunityToken.intervalDaysOf(today, tomorrow - 1, 1)).to.equal(false, "0 to +86399");
    expect(await pceCommunityToken.intervalDaysOf(today, tomorrow, 1)).to.equal(true, "0 to +86400");
    expect(await pceCommunityToken.intervalDaysOf(today, tomorrow, 2)).to.equal(false, "0 to +86400");
    expect(await pceCommunityToken.intervalDaysOf(today, next2Day, 2)).to.equal(true, "0 to +86400*2");
  });

  it("isAllowOutgoExchange", async function () {
    const tx = await pceToken.createToken(
      "A",
      "A",
      100,
      ethers.utils.parseEther("1"),
      7,
      20,
      3,
      3,
      1,
      1,
      ExchangeAllowMethod.All,
      ExchangeAllowMethod.All,
      [],
      [],
    );
    const rec = await tx.wait();
    let aTokenAddress;
    if (rec.events) {
      for (const event of rec.events) {
        if (event.event === "TokenCreated" && event.args) {
          aTokenAddress = event.args[0];
        }
      }
    }
    expect(aTokenAddress.length).to.equal(42);

    const aTokenAsPCECommunityToken = (await ethers.getContractAt(
      "PCECommunityToken",
      aTokenAddress,
    )) as PCECommunityToken;

    const txb = await pceToken.createToken(
      "B",
      "B",
      100,
      ethers.utils.parseEther("1"),
      7,
      20,
      1,
      1,
      1,
      1,
      ExchangeAllowMethod.Include,
      ExchangeAllowMethod.Include,
      [aTokenAddress],
      [aTokenAddress],
    );
    const recb = await txb.wait();
    let bTokenAddress;
    if (recb.events) {
      for (const event of recb.events) {
        if (event.event === "TokenCreated" && event.args) {
          bTokenAddress = event.args[0];
        }
      }
    }
    expect(bTokenAddress.length).to.equal(42);

    const bTokenAsPCECommunityToken = (await ethers.getContractAt(
      "PCECommunityToken",
      bTokenAddress,
    )) as PCECommunityToken;

    expect(await aTokenAsPCECommunityToken.isAllowOutgoExchange(aTokenAddress)).to.equal(true);
    expect(await aTokenAsPCECommunityToken.isAllowOutgoExchange(bTokenAddress)).to.equal(true);
    expect(await aTokenAsPCECommunityToken.isAllowIncomeExchange(aTokenAddress)).to.equal(true);
    expect(await aTokenAsPCECommunityToken.isAllowIncomeExchange(bTokenAddress)).to.equal(true);

    expect(await bTokenAsPCECommunityToken.isAllowOutgoExchange(aTokenAddress)).to.equal(true);
    expect(await bTokenAsPCECommunityToken.isAllowOutgoExchange(bTokenAddress)).to.equal(false);
    expect(await bTokenAsPCECommunityToken.isAllowIncomeExchange(aTokenAddress)).to.equal(true);
    expect(await bTokenAsPCECommunityToken.isAllowIncomeExchange(bTokenAddress)).to.equal(false);
  });

  it("transfer", async function () {
    // アカウント A, B を作成
    const [owner, accountA, accountB] = await ethers.getSigners();
    expect(owner.address.length).to.equal(42);

    await pceCommunityToken.transfer(accountA.address, ethers.utils.parseEther("100"));
    expect(await pceCommunityToken.balanceOf(accountA.address)).to.equal(ethers.utils.parseEther("100"));

    await pceCommunityToken.connect(accountA).transfer(accountB.address, ethers.utils.parseEther("30"));
    expect(await pceCommunityToken.balanceOf(accountA.address)).to.equal(ethers.utils.parseEther("70.02"));
    expect(await pceCommunityToken.balanceOf(accountB.address)).to.equal(ethers.utils.parseEther("30"));
  });

  it("setTokenSettings/agetTokenSettings", async function () {
    await pceCommunityToken.setTokenSettings(
      102, // decreaseIntervalDays
      93, // afterDecreaseBp
      22, // maxIncreaseOfTotalSupplyBp
      2001, // maxIncreaseBp
      3002, // maxUsageBp
      3003, // changeBp
      ExchangeAllowMethod.Include, // incomeAllowMethod
      ExchangeAllowMethod.Exclude, // outgoAllowMethod
      [pceCommunityToken.address], // incomeTargetTokens
      [pceCommunityToken.address], // outgoTargetTokens
    );
    const [
      decreaseIntervalDays,
      afterDecreaseBp,
      maxIncreaseOfTotalSupplyBp,
      maxIncreaseBp,
      maxUsageBp,
      changeBp,
      incomeAllowMethod,
      outgoAllowMethod,
      incomeTargetTokens,
      outgoTargetTokens,
    ] = await pceCommunityToken.getTokenSettings();
    expect(decreaseIntervalDays).to.equal(102);
    expect(afterDecreaseBp).to.equal(93);
    expect(maxIncreaseOfTotalSupplyBp).to.equal(22);
    expect(maxIncreaseBp).to.equal(2001);
    expect(maxUsageBp).to.equal(3002);
    expect(changeBp).to.equal(3003);
    expect(incomeAllowMethod).to.equal(ExchangeAllowMethod.Include);
    expect(outgoAllowMethod).to.equal(ExchangeAllowMethod.Exclude);
    expect(incomeTargetTokens.length).to.equal(1);
    expect(incomeTargetTokens[0]).to.equal(pceCommunityToken.address);
    expect(outgoTargetTokens.length).to.equal(1);
    expect(outgoTargetTokens[0]).to.equal(pceCommunityToken.address);
  });

  // it("midnightTotalSupply", async function () {
  //   expect(await pceCommunityToken.midnightTotalSupply()).to.equal(0);
  //   expect(await pceCommunityToken.midnightTotalSupplyModifiedTime()).to.equal(0);
  //   expect(await pceCommunityToken.arigatoCreationMintToday()).to.equal(0);
  //   expect(await pceCommunityToken.arigatoCreationMintTodayForGuest()).to.equal(0);
  //});

  //it("isWednesdayBetween", async function () {
  //  const wednesdayStart = dayjs.utc("2029-06-06 00:00:00").unix();
  //  const nextWednesdayStart = dayjs.utc("2029-06-13 00:00:00").unix();

  //  expect(await pceCommunityToken.isWednesdayBetween(wednesdayStart - 2, wednesdayStart - 1)).to.equal(false, "-2 to -1");

  //  expect(await pceCommunityToken.isWednesdayBetween(wednesdayStart - 1, wednesdayStart)).to.equal(true, "-1 to 0");

  //  expect(await pceCommunityToken.isWednesdayBetween(wednesdayStart, wednesdayStart)).to.equal(false, "0 to 0");

  //  expect(await pceCommunityToken.isWednesdayBetween(wednesdayStart, wednesdayStart + 1)).to.equal(false, "0 to 1");

  //  expect(await pceCommunityToken.isWednesdayBetween(wednesdayStart, nextWednesdayStart - 1)).to.equal(
  //    false,
  //    "0 to next -1",
  //  );

  //  expect(await pceCommunityToken.isWednesdayBetween(wednesdayStart, nextWednesdayStart)).to.equal(true, "0 to next 0");

  //  expect(await pceCommunityToken.isWednesdayBetween(wednesdayStart + 1, nextWednesdayStart)).to.equal(true, "1 to next 0");
  //});
});
