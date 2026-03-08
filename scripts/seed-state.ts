import { ethers } from "hardhat";
import "dotenv/config";

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value || value.trim() === "") {
    throw new Error(`Missing env var: ${name}`);
  }
  return value;
}

async function main() {
  const [admin, memberA, memberB, memberC, recipient] = await ethers.getSigners();

  const governanceAddress = requiredEnv("GOVERNANCE_ADDRESS");
  const operationalAddress = requiredEnv("OPERATIONAL_TREASURY_ADDRESS");
  const investmentAddress = requiredEnv("INVESTMENT_TREASURY_ADDRESS");
  const reserveAddress = requiredEnv("RESERVE_TREASURY_ADDRESS");

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
