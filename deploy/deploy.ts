import { ethers } from "hardhat";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const { deploy } = hre.deployments;

  // Deploy AuctionFactory
  const auctionFactory = await deploy("AuctionFactory", {
    from: deployer,
    args: [],
    log: true,
  });
  console.log(`AuctionFactory contract deployed at: ${auctionFactory.address}`);

  const asset = await deploy("MockERC20", {
    from: deployer,
    args: ["Asset Token", "AST", ethers.parseEther("10000000000000000000")],
    log: true,
  });
  console.log(`Asset contract deployed at: ${asset.address}`);

  const paymentToken = await deploy("MockERC20", {
    from: deployer,
    args: ["Payment Token", "PAY", ethers.parseEther("10000000000000000000")],
    log: true,
  });
  console.log(`PaymentToken contract deployed at: ${paymentToken.address}`);
};
export default func;
func.id = "deploy_auctionContracts"; // ID required to prevent reexecution
func.tags = ["AuctionFactory", "PrivateSingleAuction"];
