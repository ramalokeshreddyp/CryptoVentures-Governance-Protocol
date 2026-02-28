import { ethers } from "hardhat";
import "dotenv/config";

function envUint(name: string, fallback: number): bigint {
  const value = process.env[name];
  if (!value || value.trim() === "") {
    return BigInt(fallback);
  }
  return BigInt(value);
}

function envEth(name: string, fallback: string): bigint {
  const value = process.env[name] && process.env[name]!.trim() !== ""
    ? process.env[name]!
    : fallback;
  return ethers.parseEther(value);
}

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("Deploying with:", deployer.address);

  /*//////////////////////////////////////////////////////////////
                        GOVERNANCE TOKEN
  //////////////////////////////////////////////////////////////*/

  const Votes = await ethers.getContractFactory("GovernanceVotes");
  const votes = await Votes.deploy(
    "CryptoVentures DAO",
    "CVDAO",
    deployer.address
  );
  await votes.waitForDeployment();

  console.log("GovernanceVotes:", await votes.getAddress());

  /*//////////////////////////////////////////////////////////////
                          TIMELOCK
  //////////////////////////////////////////////////////////////*/

  const minDelay = envUint("GOV_MIN_DELAY_SECONDS", 2 * 24 * 60 * 60);

  const Timelock = await ethers.getContractFactory("GovernanceTimelock");
  const timelock = await Timelock.deploy(
    minDelay,
    [deployer.address],
    [deployer.address],
    deployer.address
  );
  await timelock.waitForDeployment();

  console.log("Timelock:", await timelock.getAddress());

  /*//////////////////////////////////////////////////////////////
                        GOVERNANCE CORE
  //////////////////////////////////////////////////////////////*/

  const votingDelay = envUint("GOV_VOTING_DELAY_BLOCKS", 1);
  const votingPeriod = envUint("GOV_VOTING_PERIOD_BLOCKS", 45818);
  const quorumBps = envUint("GOV_QUORUM_BPS", 2000);
  const proposalThreshold = envEth("GOV_PROPOSAL_THRESHOLD_ETH", "100");

  const Gov = await ethers.getContractFactory("GovernanceCore");
  const governance = await Gov.deploy(
    await votes.getAddress(),
    await timelock.getAddress(),
    deployer.address,
    votingDelay,
    votingPeriod,
    quorumBps,
    proposalThreshold
  );
  await governance.waitForDeployment();

  console.log("GovernanceCore:", await governance.getAddress());

  const PROPOSER_ROLE = await timelock.PROPOSER_ROLE();
  const EXECUTOR_ROLE = await timelock.EXECUTOR_ROLE();

  await timelock.grantRole(PROPOSER_ROLE, await governance.getAddress());
  await timelock.grantRole(EXECUTOR_ROLE, await governance.getAddress());

  console.log("Timelock roles granted to GovernanceCore");

  /*//////////////////////////////////////////////////////////////
                        TREASURIES
  //////////////////////////////////////////////////////////////*/

  const Operational = await ethers.getContractFactory("OperationalTreasury");
  const operationalMaxEthTransfer = envEth("OPERATIONAL_MAX_ETH_TRANSFER", "10");
  const operational = await Operational.deploy(
    await timelock.getAddress(),
    operationalMaxEthTransfer
  );
  await operational.waitForDeployment();

  console.log("OperationalTreasury:", await operational.getAddress());

  const Investment = await ethers.getContractFactory("InvestmentTreasury");
  const investmentMaxEthTransfer = envEth("INVESTMENT_MAX_ETH_TRANSFER", "100");
  const investment = await Investment.deploy(
    await timelock.getAddress(),
    investmentMaxEthTransfer
  );
  await investment.waitForDeployment();

  console.log("InvestmentTreasury:", await investment.getAddress());

  const Reserve = await ethers.getContractFactory("ReserveTreasury");
  const reserve = await Reserve.deploy(await timelock.getAddress());
  await reserve.waitForDeployment();

  console.log("ReserveTreasury:", await reserve.getAddress());

  await governance.setProposalTypeTreasury(0, await operational.getAddress());
  await governance.setProposalTypeTreasury(1, await investment.getAddress());
  await governance.setProposalTypeTreasury(2, await reserve.getAddress());

  console.log("Proposal-type treasury mapping configured");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
