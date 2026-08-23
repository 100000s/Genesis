import { ethers } from "hardhat";
import * as dotenv from "dotenv";

dotenv.config();

async function main() {
  const contractAddress = process.env.CONTRACT_ADDRESS;
  if (!contractAddress) {
    throw new Error("Missing CONTRACT_ADDRESS in .env file");
  }

  const [signer] = await ethers.getSigners();
  console.log("Triggering oracle update using account:", signer.address);

  const genesisIssuance = await ethers.getContractAt("GenesisIssuance", contractAddress, signer);

  // Example trigger call (adjust parameters according to your specific contract function)
  const tx = await genesisIssuance.getDailyPerCapitaCap();
  console.log("Current Daily Cap:", ethers.formatEther(tx));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
