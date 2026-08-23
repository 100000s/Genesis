import { ethers } from "hardhat";

async function main() {
  const [deployer, oracleSigner] = await ethers.getSigners();

  console.log("Deploying GenesisIssuance with account:", deployer.address);
  console.log("Authorized Oracle Signer:", oracleSigner.address);

  const GenesisIssuance = await ethers.getContractFactory("GenesisIssuance");
  const genesisIssuance = await GenesisIssuance.deploy(oracleSigner.address);

  await genesisIssuance.waitForDeployment();

  const deployedAddress = await genesisIssuance.getAddress();
  console.log("=========================================");
  console.log("GenesisIssuance deployed to:", deployedAddress);
  console.log("=========================================");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
