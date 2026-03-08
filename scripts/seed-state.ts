import { ethers } from "hardhat";
import "dotenv/config";
import { readFile } from "node:fs/promises";

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value || value.trim() === "") {
    throw new Error(`Missing env var: ${name}`);
  }
  return value;
}

type DeploymentFile = {
  governance: string;
  operationalTreasury: string;
  investmentTreasury: string;
  reserveTreasury: string;
};

async function tryReadDeploymentFile(): Promise<DeploymentFile | null> {
  try {
    const raw = await readFile("deployments/localhost.json", "utf-8");
    const parsed = JSON.parse(raw) as DeploymentFile;
    if (
      parsed.governance &&
      parsed.operationalTreasury &&
      parsed.investmentTreasury &&
      parsed.reserveTreasury
    ) {
      return parsed;
    }
    return null;
  } catch {
    return null;
  }
}

async function main() {
  const [admin, memberA, memberB, memberC, recipient] = await ethers.getSigners();
  if (!admin) {
    throw new Error(
      "No signer available. Start `npx hardhat node` for localhost or set DEPLOYER_PRIVATE_KEY in .env"
    );
  }

  const deployment = await tryReadDeploymentFile();

  const governanceAddress = deployment?.governance ?? requiredEnv("GOVERNANCE_ADDRESS");
  const operationalAddress =
    deployment?.operationalTreasury ?? requiredEnv("OPERATIONAL_TREASURY_ADDRESS");
  const investmentAddress =
    deployment?.investmentTreasury ?? requiredEnv("INVESTMENT_TREASURY_ADDRESS");
  const reserveAddress = deployment?.reserveTreasury ?? requiredEnv("RESERVE_TREASURY_ADDRESS");

  const governance = await ethers.getContractAt("GovernanceCore", governanceAddress);

  const governorRole = await governance.GOVERNOR_ROLE();
  await governance.grantRole(governorRole, memberA.address);
  await governance.grantRole(governorRole, memberB.address);
  await governance.grantRole(governorRole, memberC.address);

  await admin.sendTransaction({ to: operationalAddress, value: ethers.parseEther("80") });
  await admin.sendTransaction({ to: investmentAddress, value: ethers.parseEther("240") });
  await admin.sendTransaction({ to: reserveAddress, value: ethers.parseEther("480") });

  await governance.connect(admin).deposit({ value: ethers.parseEther("200") });
  await governance.connect(memberA).deposit({ value: ethers.parseEther("120") });
  await governance.connect(memberB).deposit({ value: ethers.parseEther("90") });
  await governance.connect(memberC).deposit({ value: ethers.parseEther("70") });

  await governance.connect(memberC).delegateVotingPower(memberB.address);

  // Local seeding resilience: if configured threshold is above current admin power,
  // lower only the operational threshold so sample proposal creation can proceed.
  const adminPower = await governance.currentVotingPower(admin.address);
  const operationalConfig = await governance.getProposalTypeConfig(0);
  const configuredThreshold = operationalConfig[0] as bigint;
  if (configuredThreshold > adminPower) {
    const loweredThreshold = adminPower > 1n ? adminPower - 1n : 1n;
    await governance.setProposalTypeConfig(
      0,
      loweredThreshold,
      operationalConfig[1],
      operationalConfig[2],
      operationalConfig[3]
    );
  }

  await governance.connect(admin).propose(
    0,
    recipient.address,
    ethers.parseEther("5"),
    "Seeded operational expense"
  );

  const proposalId = await governance.proposalCount();

  await ethers.provider.send("hardhat_mine", ["0x2"]);
  await governance.connect(admin).castVote(proposalId, 1);
  await governance.connect(memberA).castVote(proposalId, 1);
  await governance.connect(memberB).castVote(proposalId, 1);

  await ethers.provider.send("hardhat_mine", ["0xb300"]);

  await governance.connect(admin).queue(proposalId);

  console.log("Seed complete");
  console.log("Governance:", governanceAddress);
  console.log("Proposal queued:", proposalId.toString());
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
