import { task } from "hardhat/config";
import type { TaskArguments } from "hardhat/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

import { PrivateSinglePriceAuction } from "../types";

task("endAuction")
  .addParam("auctionContract", "Auction Contract Address")
  .setAction(async function (taskArguments: TaskArguments, hre: HardhatRuntimeEnvironment) {
    const { ethers } = hre;
    const signers = await ethers.getSigners();
    const privateAuction = (await ethers.getContractAt(
      "PrivateSinglePriceAuction",
      taskArguments.auctionContract,
    )) as PrivateSinglePriceAuction;

    const tx = await privateAuction.connect(signers[1]).settleAuction();
    const rcpt = await tx.wait();
    console.info("End Auction tx hash: ", rcpt!.hash);
    console.info("End Auction done!");
  });
