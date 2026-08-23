import { expect } from "chai";
import { ethers } from "hardhat";
import { GenesisIssuance } from "../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { time } from "@nomicfoundation/hardhat-network-helpers";

describe("GenesisIssuance Smart Contract", function () {
  let genesisIssuance: GenesisIssuance;
  let owner: HardhatEthersSigner;
  let oracleNode: HardhatEthersSigner;
  let user1: HardhatEthersSigner;
  let user2: HardhatEthersSigner;
  let users: HardhatEthersSigner[];

  const WAD = ethers.parseEther("1.0");
  const ONE_DAY = 24 * 60 * 60;
  const ROLLING_WINDOW = 28 * ONE_DAY;

  // Helper to generate native ECDSA signatures matching Solidity's recover
  async function createOracleSignature(
    signer: HardhatEthersSigner,
    priceInFiatWad: bigint,
    timestamp: number,
    chainId: bigint
  ): Promise<string> {
    const messageHash = ethers.solidityPackedKeccak256(
      ["uint256", "uint256", "uint256"],
      [priceInFiatWad, timestamp, chainId]
    );
    // Sign the raw bytes (equivalent to toEthSignedMessageHash)
    return await signer.signMessage(ethers.getBytes(messageHash));
  }

  beforeEach(async function () {
    [owner, oracleNode, user1, user2, ...users] = await ethers.getSigners();

    const GenesisIssuanceFactory = await ethers.getContractFactory("GenesisIssuance");
    genesisIssuance = await GenesisIssuanceFactory.deploy(oracleNode.address);
    await genesisIssuance.waitForDeployment();
  });

  describe("Native ECDSA Gold Price Oracle", function () {
    it("Should accept a valid signature from the authorized oracle node", async function () {
      const priceWad = ethers.parseEther("2500.50"); // $2500.50
      const currentTimestamp = await time.latest();
      const network = await ethers.provider.getNetwork();

      const signature = await createOracleSignature(
        oracleNode,
        priceWad,
        currentTimestamp,
        network.chainId
      );

      await expect(
        genesisIssuance.updateGoldPriceDirect(priceWad, currentTimestamp, signature)
      )
        .to.emit(genesisIssuance, "GoldPriceUpdated")
        .withArgs(currentTimestamp, priceWad);

      expect(await genesisIssuance.latestGoldPriceWad()).to.equal(priceWad);
      expect(await genesisIssuance.lastGoldPriceTimestamp()).to.equal(currentTimestamp);
    });

    it("Should reject updates signed by an unauthorized key", async function () {
      const priceWad = ethers.parseEther("2600.00");
      const currentTimestamp = await time.latest();
      const network = await ethers.provider.getNetwork();

      // Sign with user1 instead of oracleNode
      const invalidSignature = await createOracleSignature(
        user1,
        priceWad,
        currentTimestamp,
        network.chainId
      );

      await expect(
        genesisIssuance.updateGoldPriceDirect(priceWad, currentTimestamp, invalidSignature)
      ).to.be.revertedWithCustomError(genesisIssuance, "InvalidNodeSignature");
    });

    it("Should reject stale oracle price timestamps older than 2 hours", async function () {
      const priceWad = ethers.parseEther("2500.00");
      const currentTimestamp = await time.latest();
      const staleTimestamp = currentTimestamp - (2 * 3600 + 1); // 2 hours + 1 sec
      const network = await ethers.provider.getNetwork();

      const signature = await createOracleSignature(
        oracleNode,
        priceWad,
        staleTimestamp,
        network.chainId
      );

      await expect(
        genesisIssuance.updateGoldPriceDirect(priceWad, staleTimestamp, signature)
      ).to.be.revertedWithCustomError(genesisIssuance, "StaleOracleData");
    });
  });

  describe("Daily Claims & 24-Hour Rate Limits", function () {
    it("Should allow a valid citizen withdrawal up to the initial bootstrap cap", async function () {
      const initialCap = await genesisIssuance.INITIAL_DAILY_CAP(); // 100 WAD
      const withdrawAmount = ethers.parseEther("50.0");

      await expect(genesisIssuance.connect(user1).withdrawCitizenDaily(withdrawAmount))
        .to.emit(genesisIssuance, "CitizenWithdrawal")
        .withArgs(user1.address, withdrawAmount, initialCap);

      expect(await genesisIssuance.lastClaimTimestamp(user1.address)).to.equal(
        await time.latest()
      );
    });

    it("Should prevent multiple claims within a 24-hour window for the same user", async function () {
      const withdrawAmount = ethers.parseEther("10.0");

      // First withdrawal succeeds
      await genesisIssuance.connect(user1).withdrawCitizenDaily(withdrawAmount);

      // Advance time by 12 hours (less than 1 day)
      await time.increase(12 * 3600);

      // Second withdrawal fails
      await expect(
        genesisIssuance.connect(user1).withdrawCitizenDaily(withdrawAmount)
      ).to.be.revertedWithCustomError(genesisIssuance, "ClaimTooFrequent");

      // Advance remaining 12 hours + 1 second
      await time.increase(12 * 3600 + 1);

      // Third withdrawal succeeds
      await expect(genesisIssuance.connect(user1).withdrawCitizenDaily(withdrawAmount)).to.not.be
        .reverted;
    });

    it("Should reject withdrawals exceeding the current daily per-capita cap", async function () {
      const initialCap = await genesisIssuance.INITIAL_DAILY_CAP();
      const excessAmount = initialCap + ethers.parseEther("1.0");

      await expect(
        genesisIssuance.connect(user1).withdrawCitizenDaily(excessAmount)
      ).to.be.revertedWithCustomError(genesisIssuance, "ExceedsDailyPerCapitaLimit");
    });
  });

  describe("Rolling 28-Day Window & Dynamic Cap Calculation", function () {
    it("Should return INITIAL_DAILY_CAP when active claimants < 100", async function () {
      const cap = await genesisIssuance.getDailyPerCapitaCap();
      expect(cap).to.equal(await genesisIssuance.INITIAL_DAILY_CAP());
    });

    it("Should dynamically adjust the daily cap based on 28-day window claims when claimants >= 100", async function () {
      // Simulate 100 distinct users making withdrawals
      const claimAmount = ethers.parseEther("10.0");

      for (let i = 0; i < 100; i++) {
        const testUser = users[i];
        await genesisIssuance.connect(testUser).withdrawCitizenDaily(claimAmount);
      }

      // Total claims in window = 100 * 10 = 1000 WAD
      // Max pool with +0.5% growth = 1000 * 1005 / 1000 = 1005 WAD
      // Dynamic Daily Cap = 1005 WAD / (28 * 100) = 0.358928571428571428 WAD
      const calculatedCap = await genesisIssuance.getDailyPerCapitaCap();
      const expectedCap = (1005n * WAD * 1000n) / (1000n * 28n * 100n);

      expect(calculatedCap).to.equal(expectedCap);
    });

    it("Should exclude claims older than 28 days from the rolling cap calculation", async function () {
      // 1. Simulate 100 users claiming on Day 1
      const claimAmount = ethers.parseEther("20.0");
      for (let i = 0; i < 100; i++) {
        await genesisIssuance.connect(users[i]).withdrawCitizenDaily(claimAmount);
      }

      const day1Cap = await genesisIssuance.getDailyPerCapitaCap();

      // 2. Fast forward 29 days (past the 28-day rolling window)
      await time.increase(29 * ONE_DAY);

      // 3. Since all claims expired outside the 28-day window, active claimants drops back to 0
      // Contract defaults back to INITIAL_DAILY_CAP
      const postExpiryCap = await genesisIssuance.getDailyPerCapitaCap();
      expect(postExpiryCap).to.equal(await genesisIssuance.INITIAL_DAILY_CAP());
      expect(postExpiryCap).to.be.greaterThan(day1Cap);
    });
  });
});
