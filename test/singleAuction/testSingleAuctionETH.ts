import { expect } from "chai";
import { ethers } from "hardhat";

import { awaitAllDecryptionResults, initGateway } from "../asyncDecrypt";
import { createInstance } from "../instance";
import { reencryptEuint256 } from "../reencrypt";
import { getSigners, initSigners } from "../signers";

describe("AuctionFactory and PrivateSinglePriceAuction with ETH", function () {
  describe("Successful Scenario 1", function () {
    before(async function () {
      await initSigners();
      this.signers = await getSigners();
      this.fhevm = await createInstance();
      await initGateway();

      this.duration = 60;

      // Deploy an ERC20 mock token for the asset
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      this.asset = await MockERC20.connect(this.signers.alice).deploy(
        "Asset Token",
        "AST",
        ethers.parseEther("1000000"),
      );
      await this.asset.waitForDeployment();

      // Deploy AuctionFactory
      const AuctionFactory = await ethers.getContractFactory("AuctionFactory");
      this.auctionFactory = await AuctionFactory.connect(this.signers.alice).deploy();
      await this.auctionFactory.waitForDeployment();

      // Allowance of asset
      await this.asset.connect(this.signers.alice).transfer(this.signers.fred.address, ethers.parseEther("100"));
      await this.asset
        .connect(this.signers.fred)
        .approve(await this.auctionFactory.getAddress(), ethers.parseEther("100"));

      // Create an auction (ETH is used as the payment token by passing address(0))
      await this.auctionFactory.connect(this.signers.fred).createAuction(
        await this.asset.getAddress(),
        ethers.ZeroAddress, // ETH as payment token
        ethers.parseEther("100"),
        this.duration,
        50,
      );
      const auctionAddress = await this.auctionFactory.getAllAuctions();
      this.privateAuction = await ethers.getContractAt("PrivateSinglePriceAuction", auctionAddress[0]);

      // Bidder ETH balances for placing bids
      this.bidder1 = this.signers.bob;
      this.bidder2 = this.signers.carol;
      this.bidder3 = this.signers.dave;
      this.bidder4 = this.signers.eve;
    });

    it("Should have one auction and the data should match those deployed", async function () {
      // Fetch the list of all auctions
      const auctions = await this.auctionFactory.getAllAuctions();

      // Ensure there is one auction in the list
      expect(auctions.length).to.equal(1);

      // Verify the address of the created auction matches the first auction in the list
      expect(await this.privateAuction.getAddress()).to.be.equal(auctions[0]);
      expect(await this.privateAuction.owner()).to.equal(this.signers.fred.address);
      expect(await this.privateAuction.asset()).to.equal(await this.asset.getAddress());
      expect(await this.privateAuction.paymentToken()).to.equal(ethers.ZeroAddress); // ETH as payment token
      expect(await this.privateAuction.quantity()).to.equal(ethers.parseEther("100"));
      expect(await this.privateAuction.startTime()).to.be.above(0); // Auction start time should be set
      expect(await this.privateAuction.endTime()).to.be.above(await this.privateAuction.startTime()); // End time should be greater than start time
    });

    it("Should allow bidder1 to lock funds", async function () {
      // Lock funds first (for this example, assume lockFunds method is correctly implemented)
      await this.privateAuction
        .connect(this.bidder1)
        .lockFunds(ethers.parseEther("50"), { value: ethers.parseEther("50") });

      const lockedFundedBidder1 = await this.privateAuction.lockedFunds(this.bidder1.address);

      expect(lockedFundedBidder1).to.equal(ethers.parseEther("50"));
    });

    it("Should allow bidder1 to place encrypted bid with ETH", async function () {
      const price = ethers.parseEther("1");
      const quantity = ethers.parseEther("30");
      const input = this.fhevm.createEncryptedInput(await this.privateAuction.getAddress(), this.bidder1.address);
      input.add256(quantity);
      input.add256(price);
      const encryptedAmount = await input.encrypt();

      const tx = await this.privateAuction
        .connect(this.bidder1)
        ["placeEncryptedBid(bytes32,bytes32,bytes)"](
          encryptedAmount.handles[0],
          encryptedAmount.handles[1],
          encryptedAmount.inputProof,
        );
      const t2 = await tx.wait();
      expect(t2?.status).to.eq(1);

      const bids = await this.privateAuction.getAllBids();
      // Reencrypt Bob bid
      const quantityHandle = bids[0][1];
      const priceHandle = bids[0][2];
      const quantityDecrypted = await reencryptEuint256(
        this.signers.bob,
        this.fhevm,
        quantityHandle,
        await this.privateAuction.getAddress(),
      );
      const priceDecrypted = await reencryptEuint256(
        this.bidder1,
        this.fhevm,
        priceHandle,
        await this.privateAuction.getAddress(),
      );
      expect(quantityDecrypted).to.be.equal(quantity);
      expect(priceDecrypted).to.be.equal(price);
    });

    it("Should allow bidder2 to bid, however as bidder2 don't lock funds, the bid will be 0", async function () {
      const price = ethers.parseEther("20");
      const quantity = ethers.parseEther("30");
      const input = this.fhevm.createEncryptedInput(await this.privateAuction.getAddress(), this.bidder2.address);
      input.add256(quantity);
      input.add256(price);
      const encryptedAmount = await input.encrypt();

      const tx = await this.privateAuction
        .connect(this.bidder2)
        ["placeEncryptedBid(bytes32,bytes32,bytes)"](
          encryptedAmount.handles[0],
          encryptedAmount.handles[1],
          encryptedAmount.inputProof,
        );
      const t2 = await tx.wait();
      expect(t2?.status).to.eq(1);

      const bids = await this.privateAuction.getAllBids();
      // Reencrypt bid
      const quantityHandle = bids[1][1];
      const priceHandle = bids[1][2];
      const quantityDecrypted = await reencryptEuint256(
        this.bidder2,
        this.fhevm,
        quantityHandle,
        await this.privateAuction.getAddress(),
      );
      const priceDecrypted = await reencryptEuint256(
        this.bidder2,
        this.fhevm,
        priceHandle,
        await this.privateAuction.getAddress(),
      );
      expect(quantityDecrypted).to.be.equal(0);
      expect(priceDecrypted).to.be.equal(0);
    });

    it("Should allow bidder3 to bid", async function () {
      await this.privateAuction
        .connect(this.bidder3)
        .lockFunds(ethers.parseEther("1000"), { value: ethers.parseEther("1000") });

      const lockedFundedBidder3 = await this.privateAuction.lockedFunds(this.bidder3.address);

      expect(lockedFundedBidder3).to.equal(ethers.parseEther("1000"));

      const price = ethers.parseEther("1");
      const quantity = ethers.parseEther("800");
      const input = this.fhevm.createEncryptedInput(await this.privateAuction.getAddress(), this.bidder3.address);
      input.add256(quantity);
      input.add256(price);
      const encryptedAmount = await input.encrypt();

      const tx = await this.privateAuction
        .connect(this.bidder3)
        ["placeEncryptedBid(bytes32,bytes32,bytes)"](
          encryptedAmount.handles[0],
          encryptedAmount.handles[1],
          encryptedAmount.inputProof,
        );
      const t2 = await tx.wait();
      expect(t2?.status).to.eq(1);

      const bids = await this.privateAuction.getAllBids();
      // Reencrypt bid
      const quantityHandle = bids[2][1];
      const priceHandle = bids[2][2];
      const quantityDecrypted = await reencryptEuint256(
        this.bidder3,
        this.fhevm,
        quantityHandle,
        await this.privateAuction.getAddress(),
      );
      const priceDecrypted = await reencryptEuint256(
        this.bidder3,
        this.fhevm,
        priceHandle,
        await this.privateAuction.getAddress(),
      );
      expect(quantityDecrypted).to.be.equal(quantity);
      expect(priceDecrypted).to.be.equal(price);
    });

    it("Should allow bidder4 to bid", async function () {
      await this.privateAuction
        .connect(this.bidder4)
        .lockFunds(ethers.parseEther("250"), { value: ethers.parseEther("250") });

      const lockedFundedBidder4 = await this.privateAuction.lockedFunds(this.bidder4.address);

      expect(lockedFundedBidder4).to.equal(ethers.parseEther("250"));

      const price = ethers.parseEther("3");
      const quantity = ethers.parseEther("80");
      const input = this.fhevm.createEncryptedInput(await this.privateAuction.getAddress(), this.bidder4.address);
      input.add256(quantity);
      input.add256(price);
      const encryptedAmount = await input.encrypt();

      const tx = await this.privateAuction
        .connect(this.bidder4)
        ["placeEncryptedBid(bytes32,bytes32,bytes)"](
          encryptedAmount.handles[0],
          encryptedAmount.handles[1],
          encryptedAmount.inputProof,
        );
      const t2 = await tx.wait();
      expect(t2?.status).to.eq(1);

      const bids = await this.privateAuction.getAllBids();
      // Reencrypt bid
      const quantityHandle = bids[3][1];
      const priceHandle = bids[3][2];
      const quantityDecrypted = await reencryptEuint256(
        this.bidder4,
        this.fhevm,
        quantityHandle,
        await this.privateAuction.getAddress(),
      );
      const priceDecrypted = await reencryptEuint256(
        this.bidder4,
        this.fhevm,
        priceHandle,
        await this.privateAuction.getAddress(),
      );
      expect(quantityDecrypted).to.be.equal(quantity);
      expect(priceDecrypted).to.be.equal(price);
    });

    it("Should settle the auction correctly and handle ETH", async function () {
      // Fast-forward the time to after the auction has ended
      await ethers.provider.send("evm_increaseTime", [this.duration + 1]);
      await ethers.provider.send("evm_mine", []);
      let initialBalance = await ethers.provider.getBalance(this.signers.fred.address);
      await this.privateAuction.connect(this.signers.fred).settleAuction();
      await awaitAllDecryptionResults();
      await this.privateAuction.connect(this.signers.fred).distributeFunds();
      expect(await this.privateAuction.settlementPrice()).to.be.equal(ethers.parseEther("1"));
      expect(await this.asset.balanceOf(this.bidder1)).to.be.equal(ethers.parseEther("20"));
      expect(await this.asset.balanceOf(this.bidder4)).to.be.equal(ethers.parseEther("80"));
      let currentBalance = await ethers.provider.getBalance(this.signers.fred.address);
      // Gas fees also
      expect(currentBalance - initialBalance).to.be.above(ethers.parseEther("99"));
    });
  });

  describe("Successful Scenario - In the example of bounty", function () {
    before(async function () {
      await initSigners();
      this.signers = await getSigners();
      this.fhevm = await createInstance();
      await initGateway();

      this.duration = 60;

      // Deploy an ERC20 mock token for the asset
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      this.asset = await MockERC20.connect(this.signers.alice).deploy(
        "Asset Token",
        "AST",
        ethers.parseEther("1000000"),
      );
      await this.asset.waitForDeployment();

      // Deploy AuctionFactory
      const AuctionFactory = await ethers.getContractFactory("AuctionFactory");
      this.auctionFactory = await AuctionFactory.connect(this.signers.alice).deploy();
      await this.auctionFactory.waitForDeployment();

      // Allowance of asset
      await this.asset.connect(this.signers.alice).transfer(this.signers.fred.address, ethers.parseEther("1000000"));
      await this.asset
        .connect(this.signers.fred)
        .approve(await this.auctionFactory.getAddress(), ethers.parseEther("1000000"));

      // Create an auction (ETH is used as the payment token by passing address(0))
      await this.auctionFactory.connect(this.signers.fred).createAuction(
        await this.asset.getAddress(),
        ethers.ZeroAddress, // ETH as payment token
        ethers.parseEther("1000000"),
        this.duration,
        50,
      );
      const auctionAddress = await this.auctionFactory.getAllAuctions();
      this.privateAuction = await ethers.getContractAt("PrivateSinglePriceAuction", auctionAddress[0]);

      // Bidder ETH balances for placing bids
      this.bidder1 = this.signers.bob;
      this.bidder2 = this.signers.carol;
      this.bidder3 = this.signers.dave;
      this.bidder4 = this.signers.eve;
    });

    it("Should have one auction and the data should match those deployed", async function () {
      // Fetch the list of all auctions
      const auctions = await this.auctionFactory.getAllAuctions();

      // Ensure there is one auction in the list
      expect(auctions.length).to.equal(1);

      // Verify the address of the created auction matches the first auction in the list
      expect(await this.privateAuction.getAddress()).to.be.equal(auctions[0]);
      expect(await this.privateAuction.owner()).to.equal(this.signers.fred.address);
      expect(await this.privateAuction.asset()).to.equal(await this.asset.getAddress());
      expect(await this.privateAuction.paymentToken()).to.equal(ethers.ZeroAddress); // ETH as payment token
      expect(await this.privateAuction.quantity()).to.equal(ethers.parseEther("1000000"));
      expect(await this.privateAuction.startTime()).to.be.above(0); // Auction start time should be set
      expect(await this.privateAuction.endTime()).to.be.above(await this.privateAuction.startTime()); // End time should be greater than start time
    });

    it("Should allow bidder1 to lock funds", async function () {
      // Lock funds first (for this example, assume lockFunds method is correctly implemented)
      await this.privateAuction
        .connect(this.bidder1)
        .lockFunds(ethers.parseEther("2"), { value: ethers.parseEther("2") });

      const lockedFundedBidder1 = await this.privateAuction.lockedFunds(this.bidder1.address);

      expect(lockedFundedBidder1).to.equal(ethers.parseEther("2"));
    });

    it("Should allow bidder1 to place encrypted bid with ETH", async function () {
      const price = ethers.parseEther("0.000002");
      const quantity = ethers.parseEther("500000");
      const input = this.fhevm.createEncryptedInput(await this.privateAuction.getAddress(), this.bidder1.address);
      input.add256(quantity);
      input.add256(price);
      const encryptedAmount = await input.encrypt();

      const tx = await this.privateAuction
        .connect(this.bidder1)
        ["placeEncryptedBid(bytes32,bytes32,bytes)"](
          encryptedAmount.handles[0],
          encryptedAmount.handles[1],
          encryptedAmount.inputProof,
        );
      const t2 = await tx.wait();
      expect(t2?.status).to.eq(1);

      const bids = await this.privateAuction.getAllBids();
      // Reencrypt Bob bid
      const quantityHandle = bids[0][1];
      const priceHandle = bids[0][2];
      const quantityDecrypted = await reencryptEuint256(
        this.signers.bob,
        this.fhevm,
        quantityHandle,
        await this.privateAuction.getAddress(),
      );
      const priceDecrypted = await reencryptEuint256(
        this.bidder1,
        this.fhevm,
        priceHandle,
        await this.privateAuction.getAddress(),
      );
      expect(quantityDecrypted).to.be.equal(quantity);
      expect(priceDecrypted).to.be.equal(price);
    });

    it("Should allow bidder2 to bid, however as bidder2 don't lock funds, the bid will be 0", async function () {
      const price = ethers.parseEther("20");
      const quantity = ethers.parseEther("30");
      const input = this.fhevm.createEncryptedInput(await this.privateAuction.getAddress(), this.bidder2.address);
      input.add256(quantity);
      input.add256(price);
      const encryptedAmount = await input.encrypt();

      const tx = await this.privateAuction
        .connect(this.bidder2)
        ["placeEncryptedBid(bytes32,bytes32,bytes)"](
          encryptedAmount.handles[0],
          encryptedAmount.handles[1],
          encryptedAmount.inputProof,
        );
      const t2 = await tx.wait();
      expect(t2?.status).to.eq(1);

      const bids = await this.privateAuction.getAllBids();
      // Reencrypt bid
      const quantityHandle = bids[1][1];
      const priceHandle = bids[1][2];
      const quantityDecrypted = await reencryptEuint256(
        this.bidder2,
        this.fhevm,
        quantityHandle,
        await this.privateAuction.getAddress(),
      );
      const priceDecrypted = await reencryptEuint256(
        this.bidder2,
        this.fhevm,
        priceHandle,
        await this.privateAuction.getAddress(),
      );
      expect(quantityDecrypted).to.be.equal(0);
      expect(priceDecrypted).to.be.equal(0);
    });

    it("Should allow bidder3 to bid", async function () {
      await this.privateAuction
        .connect(this.bidder3)
        .lockFunds(ethers.parseEther("5"), { value: ethers.parseEther("5") });

      const lockedFundedBidder3 = await this.privateAuction.lockedFunds(this.bidder3.address);

      expect(lockedFundedBidder3).to.equal(ethers.parseEther("5"));

      const price = ethers.parseEther("0.000008");
      const quantity = ethers.parseEther("600000");
      const input = this.fhevm.createEncryptedInput(await this.privateAuction.getAddress(), this.bidder3.address);
      input.add256(quantity);
      input.add256(price);
      const encryptedAmount = await input.encrypt();

      const tx = await this.privateAuction
        .connect(this.bidder3)
        ["placeEncryptedBid(bytes32,bytes32,bytes)"](
          encryptedAmount.handles[0],
          encryptedAmount.handles[1],
          encryptedAmount.inputProof,
        );
      const t2 = await tx.wait();
      expect(t2?.status).to.eq(1);

      const bids = await this.privateAuction.getAllBids();
      // Reencrypt bid
      const quantityHandle = bids[2][1];
      const priceHandle = bids[2][2];
      const quantityDecrypted = await reencryptEuint256(
        this.bidder3,
        this.fhevm,
        quantityHandle,
        await this.privateAuction.getAddress(),
      );
      const priceDecrypted = await reencryptEuint256(
        this.bidder3,
        this.fhevm,
        priceHandle,
        await this.privateAuction.getAddress(),
      );
      expect(quantityDecrypted).to.be.equal(quantity);
      expect(priceDecrypted).to.be.equal(price);
    });

    it("Should allow bidder4 to bid", async function () {
      await this.privateAuction
        .connect(this.bidder4)
        .lockFunds(ethers.parseEther("0.1"), { value: ethers.parseEther("0.1") });

      const lockedFundedBidder4 = await this.privateAuction.lockedFunds(this.bidder4.address);

      expect(lockedFundedBidder4).to.equal(ethers.parseEther("0.1"));

      const price = ethers.parseEther("0.00000000001");
      const quantity = ethers.parseEther("1000000");
      const input = this.fhevm.createEncryptedInput(await this.privateAuction.getAddress(), this.bidder4.address);
      input.add256(quantity);
      input.add256(price);
      const encryptedAmount = await input.encrypt();

      const tx = await this.privateAuction
        .connect(this.bidder4)
        ["placeEncryptedBid(bytes32,bytes32,bytes)"](
          encryptedAmount.handles[0],
          encryptedAmount.handles[1],
          encryptedAmount.inputProof,
        );
      const t2 = await tx.wait();
      expect(t2?.status).to.eq(1);

      const bids = await this.privateAuction.getAllBids();
      // Reencrypt bid
      const quantityHandle = bids[3][1];
      const priceHandle = bids[3][2];
      const quantityDecrypted = await reencryptEuint256(
        this.bidder4,
        this.fhevm,
        quantityHandle,
        await this.privateAuction.getAddress(),
      );
      const priceDecrypted = await reencryptEuint256(
        this.bidder4,
        this.fhevm,
        priceHandle,
        await this.privateAuction.getAddress(),
      );
      expect(quantityDecrypted).to.be.equal(quantity);
      expect(priceDecrypted).to.be.equal(price);
    });

    it("Should settle the auction correctly and handle ETH", async function () {
      // Fast-forward the time to after the auction has ended
      await ethers.provider.send("evm_increaseTime", [this.duration + 1]);
      await ethers.provider.send("evm_mine", []);
      let initialBalance = await ethers.provider.getBalance(this.signers.fred.address);
      await this.privateAuction.connect(this.signers.fred).settleAuction();
      await awaitAllDecryptionResults();
      await this.privateAuction.connect(this.signers.fred).distributeFunds();
      expect(await this.privateAuction.settlementPrice()).to.be.equal(ethers.parseEther("0.000002"));
      expect(await this.asset.balanceOf(this.bidder1)).to.be.equal(ethers.parseEther("400000"));
      expect(await this.asset.balanceOf(this.bidder3)).to.be.equal(ethers.parseEther("600000"));
      let currentBalance = await ethers.provider.getBalance(this.signers.fred.address);
      // Gas fees also
      expect(currentBalance - initialBalance).to.be.above(ethers.parseEther("1.99"));
    });
  });
});
