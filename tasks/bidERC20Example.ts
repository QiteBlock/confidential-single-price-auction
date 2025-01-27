import { task } from "hardhat/config";
import type { TaskArguments } from "hardhat/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

import { MockERC20, PrivateSinglePriceAuction } from "../types";
import { bidAuction } from "./bid/bidFunctions";
import { createInstance } from "./bid/instance";

task("bid")
  .addParam("auctionContract", "Auction Contract Address")
  .addOptionalParam("paymentToken", "Payment Token Contract Address")
  .setAction(async function (taskArguments: TaskArguments, hre: HardhatRuntimeEnvironment) {
    const { ethers } = hre;
    const signers = await ethers.getSigners();
    const fhevm = await createInstance(hre.network);
    const privateAuction = (await ethers.getContractAt(
      "PrivateSinglePriceAuction",
      taskArguments.auctionContract,
    )) as PrivateSinglePriceAuction;
    const paymentToken = (await ethers.getContractAt("MockERC20", taskArguments.paymentToken)) as MockERC20;

    await paymentToken.connect(signers[0]).transfer(signers[2].address, ethers.parseEther("10000"));
    await paymentToken.connect(signers[0]).transfer(signers[3].address, ethers.parseEther("10000"));
    await paymentToken.connect(signers[0]).transfer(signers[4].address, ethers.parseEther("10000"));

    await bidAuction(0, 2, "1", "30", "50", ethers, paymentToken, privateAuction, signers, fhevm);
    await bidAuction(1, 3, "1", "800", "1000", ethers, paymentToken, privateAuction, signers, fhevm);
    await bidAuction(2, 4, "3", "80", "250", ethers, paymentToken, privateAuction, signers, fhevm);
  });
