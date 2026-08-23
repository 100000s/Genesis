import { expect } from "chai";
import { ethers, network } from "hardhat";
import { WorkerSplit, MockGenesisIssuance, MockZKVerifier } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("WorkerSplit Unit Tests", function () {
  let workerSplit: WorkerSplit;
  let mockIssuance: MockGenesisIssuance;
  let mockVerifier: MockZKVerifier;

  let owner: SignerWithAddress;
  let escrowContract: SignerWithAddress;
  let noteReserve: SignerWithAddress;
  let workerRecipient: SignerWithAddress;
  let unauthorizedUser: SignerWithAddress;

  const EPOCH_DURATION = 30 * 24 * 60 * 60; // 30 days in seconds

  beforeEach(async function () {
    [owner, escrowContract, noteReserve, workerRecipient, unauthorizedUser] = await ethers.getSigners();

    // Deploy Mock Contracts
    const MockIssuanceFactory = await ethers.getContractFactory("MockGenesisIssuance");
    mockIssuance = await MockIssuanceFactory.deploy();

    const MockVerifierFactory = await ethers.getContractFactory("MockZKVerifier");
    mockVerifier = await MockVerifierFactory.deploy();

    // Deploy WorkerSplit Contract
    const WorkerSplitFactory = await ethers.getContractFactory("WorkerSplit");
    workerSplit = await WorkerSplitFactory.deploy(
      await mockIssuance.getAddress(),
      await mockVerifier.getAddress(),
      noteReserve.address
    );

    // Set Escrow as authorized volume reporter
    await workerSplit.setVolumeReporter(escrowContract.address, true);
  });

  describe("Access Control & Initial State", function () {
    it("should initialize with epoch 1 and correct epoch duration parameters", async function () {
      expect(await workerSplit.currentEpoch()).to.equal(1);
      expect(await workerSplit.noteMaintenanceReserve()).to.equal(noteReserve.address);
    });

    it("should prevent unauthorized callers from reporting active volume", async function () {
      await expect(
        workerSplit.connect(unauthorizedUser).recordTransactionVolume(ethers.parseEther("1000"))
      ).to.be.revertedWithCustomError(workerSplit, "UnauthorizedVolumeReporter");
    });

    it("should allow authorized volume reporters to log transaction activity", async function () {
      const volume = ethers.parseEther("10000");
      await expect(workerSplit.connect(escrowContract).recordTransactionVolume(volume))
        .to.emit(workerSplit, "ActiveVolumeReported")
        .withArgs(escrowContract.address, volume);

      expect(await workerSplit.currentEpochActiveVolume()).to.equal(volume);
    });
  });

  describe("Epoch Finalization & 0.5% Mint Allocation", function () {
    it("should revert finalization if 30 days have not passed", async function () {
      await expect(workerSplit.finalizeEpoch()).to.be.revertedWithCustomError(
        workerSplit,
        "EpochNotEnded"
      );
    });

    it("should calculate 0.5% mint allocations correctly and auto-mint 2% Note Reserve", async function () {
      // Record 1,000,000 ETH worth of active transaction volume (Zero fee to users)
      const activeVolume = ethers.parseEther("1000000");
      await workerSplit.connect(escrowContract).recordTransactionVolume(activeVolume);

      // Fast-forward time by 30 days + 1 second
      await network.provider.send("evm_increaseTime", [EPOCH_DURATION + 1]);
      await network.provider.send("evm_mine");

      // Total minted pool = 0.5% of 1,000,000 = 5,000 tokens
      const expectedMintPool = ethers.parseEther("5000");
      
      // Note Reserve = 2% of total mint pool (10% of 20% Note pool) = 100 tokens
      const expectedNoteReserve = ethers.parseEther("100");

      await expect(workerSplit.finalizeEpoch())
        .to.emit(workerSplit, "EpochFinalized")
        .withArgs(1, activeVolume, expectedMintPool, 0);

      // Check auto-minting of 2% Note Maintenance Reserve directly to reserve wallet
      expect(await mockIssuance.workerBalances(noteReserve.address)).to.equal(expectedNoteReserve);

      // Check calculated pool breakdown stored on-chain
      const epochDetails = await workerSplit.getEpochPoolDetails(1);
      expect(epochDetails.finalized).to.be.true;
      expect(epochDetails.totalActiveVolume).to.equal(activeVolume);
      expect(epochDetails.totalMintedRewardPool).to.equal(expectedMintPool);
      expect(epochDetails.validatorShare).to.equal(ethers.parseEther("2000")); // 40%
      expect(epochDetails.verifierShare).to.equal(ethers.parseEther("1500"));  // 30%
      expect(epochDetails.noteHwBountyShare).to.equal(ethers.parseEther("500")); // 10%
      expect(epochDetails.notePresenceShare).to.equal(ethers.parseEther("400")); // 8%
      expect(epochDetails.noteReserveShare).to.equal(expectedNoteReserve);       // 2%
      expect(epochDetails.arbitratorShare).to.equal(ethers.parseEther("500"));  // 10%

      // Verify advancement to Epoch 2
      expect(await workerSplit.currentEpoch()).to.equal(2);
      expect(await workerSplit.currentEpochActiveVolume()).to.equal(0);
    });
  });

  describe("Fee/Mint Rollover on Low Network Activity", function () {
    it("should carry over zero-volume pools into rollover balance for the next month", async function () {
      // Epoch 1 ends with ZERO active transactions
      await network.provider.send("evm_increaseTime", [EPOCH_DURATION + 1]);
      await network.provider.send("evm_mine");

      await workerSplit.finalizeEpoch();
      expect(await workerSplit.rolloverBalance()).to.equal(0);

      // Epoch 2 records 200,000 active volume
      const volumeEpoch2 = ethers.parseEther("200000");
      await workerSplit.connect(escrowContract).recordTransactionVolume(volumeEpoch2);

      await network.provider.send("evm_increaseTime", [EPOCH_DURATION + 1]);
      await network.provider.send("evm_mine");

      // 0.5% of 200,000 = 1,000 tokens minted
      const expectedMintPool = ethers.parseEther("1000");

      await expect(workerSplit.finalizeEpoch())
        .to.emit(workerSplit, "EpochFinalized")
        .withArgs(2, volumeEpoch2, expectedMintPool, 0);

      const epoch2Details = await workerSplit.getEpochPoolDetails(2);
      expect(epoch2Details.totalMintedRewardPool).to.equal(expectedMintPool);
    });
  });

  describe("Anonymous ZK Reward Claiming", function () {
    const epochId = 1;
    const nullifierHash = ethers.keccak256(ethers.toUtf8Bytes("nullifier_secret_123"));
    const claimAmount = ethers.parseEther("250");
    const subPool = 0; // VALIDATOR
    const dummyProof = "0x1234567890abcdef";

    beforeEach(async function () {
      // Populate and finalize Epoch 1
      await workerSplit.connect(escrowContract).recordTransactionVolume(ethers.parseEther("1000000"));
      await network.provider.send("evm_increaseTime", [EPOCH_DURATION + 1]);
      await network.provider.send("evm_mine");
      await workerSplit.finalizeEpoch();
    });

    it("should allow a valid ZK proof claim to mint tokens directly to a fresh unlinked address", async function () {
      await expect(
        workerSplit.claimRewardAnonymous(
          dummyProof,
          nullifierHash,
          workerRecipient.address,
          claimAmount,
          subPool,
          epochId
        )
      )
        .to.emit(workerSplit, "AnonymousRewardClaimed")
        .withArgs(nullifierHash, workerRecipient.address, claimAmount, subPool, epochId);

      // Assert tokens were freshly minted to the specified recipient address
      expect(await mockIssuance.workerBalances(workerRecipient.address)).to.equal(claimAmount);
      
      // Assert nullifier is marked spent permanently
      expect(await workerSplit.nullifierSpent(nullifierHash)).to.be.true;
    });

    it("should revert when attempting to re-use an already spent nullifier", async function () {
      // First claim
      await workerSplit.claimRewardAnonymous(
        dummyProof,
        nullifierHash,
        workerRecipient.address,
        claimAmount,
        subPool,
        epochId
      );

      // Duplicate claim attempt with same nullifier
      await expect(
        workerSplit.claimRewardAnonymous(
          dummyProof,
          nullifierHash,
          workerRecipient.address,
          claimAmount,
          subPool,
          epochId
        )
      ).to.be.revertedWithCustomError(workerSplit, "NullifierAlreadyUsed");
    });

    it("should revert if the ZK proof verification fails", async function () {
      // Set ZK Verifier mock to reject proof
      await mockVerifier.setShouldPass(false);

      const unusedNullifier = ethers.keccak256(ethers.toUtf8Bytes("nullifier_secret_456"));

      await expect(
        workerSplit.claimRewardAnonymous(
          dummyProof,
          unusedNullifier,
          workerRecipient.address,
          claimAmount,
          subPool,
          epochId
        )
      ).to.be.revertedWithCustomError(workerSplit, "InvalidZKProof");
    });

    it("should revert when attempting to claim for an unfinalized epoch", async function () {
      const unusedNullifier = ethers.keccak256(ethers.toUtf8Bytes("nullifier_secret_789"));

      await expect(
        workerSplit.claimRewardAnonymous(
          dummyProof,
          unusedNullifier,
          workerRecipient.address,
          claimAmount,
          subPool,
          2 // Unfinalized epoch
        )
      ).to.be.revertedWithCustomError(workerSplit, "EpochNotFinalized");
    });
  });
});
