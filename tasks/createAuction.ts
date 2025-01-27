import { task } from "hardhat/config";
import type { TaskArguments } from "hardhat/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

import { AuctionFactory, MockERC20 } from "../types";

// Auction Factory Contract 0xe13a2C0cD324aaf9Db5E9FdFDba532Ea7Fa5681c
// Asset Token Contract 0x21D7A817AC349Bacb8d11A7a8816F0234c04be4a
// Payment Token Contract 0x364Af1aD133c171EC952C632B3Adcdaed4d7A0B4
task("createAuction")
  .addParam("auctionFactoryContract", "Auction Factory Contract Address")
  .addParam("assetContract", "Asset Contract Address")
  .addParam("quantity", "Quantity")
  .addParam("duration", "Duration")
  .addParam("maxParticipant", "Max Participant")
  .addOptionalParam("paymentToken", "Payment Token Contract Address")
  .setAction(async function (taskArguments: TaskArguments, hre: HardhatRuntimeEnvironment) {
    const { ethers } = hre;
    const signers = await ethers.getSigners();
    const auctionFactory = (await ethers.getContractAt(
      "AuctionFactory",
      taskArguments.auctionFactoryContract,
    )) as AuctionFactory;
    const asset = (await ethers.getContractAt("MockERC20", taskArguments.assetContract)) as MockERC20;
    let paymentToken = ethers.ZeroAddress;
    if (taskArguments.paymentToken) {
      const paymentTokenContract = (await ethers.getContractAt("MockERC20", taskArguments.paymentToken)) as MockERC20;
      paymentToken = await paymentTokenContract.getAddress();
    }

    await asset.connect(signers[0]).transfer(signers[1], ethers.parseEther(taskArguments.quantity));
    await asset
      .connect(signers[1])
      .approve(await auctionFactory.getAddress(), ethers.parseEther(taskArguments.quantity));
    const tx = await auctionFactory
      .connect(signers[1])
      .createAuction(
        await asset.getAddress(),
        paymentToken,
        ethers.parseEther(taskArguments.quantity),
        taskArguments.duration,
        taskArguments.maxParticipant,
      );
    const rcpt = await tx.wait();
    console.info("Create Auction tx hash: ", rcpt!.hash);
    console.info("Create Auction done!");
  });
