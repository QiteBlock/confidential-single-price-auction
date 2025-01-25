import { task } from "hardhat/config";
import type { TaskArguments } from "hardhat/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

import { AuctionFactory, MockERC20 } from "../types";

// Auction Factory Contract 0x47e1Cbd5Df5FdA44AF626d148C2ce11D43909Ae7
// Asset Token Contract 0x6aC105042b2F5865972CEC83EFF6fE96c9583779
// Payment Token Contract 0x5d09902624B8DE574EB7632B4CD57B0fB9c7a933
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
