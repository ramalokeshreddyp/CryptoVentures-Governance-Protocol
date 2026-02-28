import { expect } from "chai";
import { ethers } from "hardhat";

function sqrtBigInt(value: bigint): bigint {
  if (value < 2n) return value;

  let left = 1n;
  let right = value;
  let answer = 1n;

  while (left <= right) {
    const mid = (left + right) / 2n;
    const sq = mid * mid;

    if (sq === value) return mid;
    if (sq < value) {
      answer = mid;
      left = mid + 1n;
    } else {
      right = mid - 1n;
    }
  }

  return answer;
}

describe("CryptoVentures DAO – Security Regression", function () {
  async function deployFixture() {
    const [admin, voter1, voter2, attacker, recipient] = await ethers.getSigners();

    const Votes = await ethers.getContractFactory("GovernanceVotes");
    const votes = await Votes.deploy("CryptoVentures DAO", "CVDAO", admin.address);
    await votes.waitForDeployment();

    const minDelay = 2 * 24 * 60 * 60;
    const Timelock = await ethers.getContractFactory("GovernanceTimelock");
    const timelock = await Timelock.deploy(
      minDelay,
      [admin.address],
      [admin.address],
      admin.address
    );
    await timelock.waitForDeployment();

    const votingDelay = 1;
    const votingPeriod = 45818;
    const quorumBps = 2000;
    const proposalThreshold = 10_000_000_000n;

    const Gov = await ethers.getContractFactory("GovernanceCore");
    const governance = await Gov.deploy(
      await votes.getAddress(),
      await timelock.getAddress(),
      admin.address,
      votingDelay,
      votingPeriod,
      quorumBps,
      proposalThreshold
    );
    await governance.waitForDeployment();

    const PROPOSER_ROLE = await timelock.PROPOSER_ROLE();
    const TIMELOCK_EXECUTOR_ROLE = await timelock.EXECUTOR_ROLE();

    await timelock.grantRole(PROPOSER_ROLE, await governance.getAddress());
    await timelock.grantRole(TIMELOCK_EXECUTOR_ROLE, await governance.getAddress());

    const Operational = await ethers.getContractFactory("OperationalTreasury");
    const operational = await Operational.deploy(
      await timelock.getAddress(),
      ethers.parseEther("10")
    );
    await operational.waitForDeployment();

    const Investment = await ethers.getContractFactory("InvestmentTreasury");
    const investment = await Investment.deploy(
      await timelock.getAddress(),
      ethers.parseEther("100")
    );
    await investment.waitForDeployment();

    const Reserve = await ethers.getContractFactory("ReserveTreasury");
    const reserve = await Reserve.deploy(await timelock.getAddress());
    await reserve.waitForDeployment();

    await governance.setProposalTypeTreasury(0, await operational.getAddress());
    await governance.setProposalTypeTreasury(1, await investment.getAddress());
    await governance.setProposalTypeTreasury(2, await reserve.getAddress());

    const GOVERNOR_ROLE = await governance.GOVERNOR_ROLE();
    await governance.grantRole(GOVERNOR_ROLE, voter1.address);
    await governance.grantRole(GOVERNOR_ROLE, voter2.address);

    await votes.mint(admin.address, ethers.parseEther("200"));
    await votes.mint(voter1.address, ethers.parseEther("100"));
    await votes.mint(voter2.address, ethers.parseEther("100"));

    await votes.connect(admin).delegate(admin.address);
    await votes.connect(voter1).delegate(voter1.address);
    await votes.connect(voter2).delegate(voter2.address);

    await ethers.provider.send("evm_mine", []);

    return {
      admin,
      voter1,
      voter2,
      attacker,
      recipient,
      votes,
      governance,
      timelock,
      operational,
      investment,
      reserve,
    };
  }

  it("rejects unauthorized treasury transfer entrypoints", async function () {
    const { attacker, operational, investment, reserve } = await deployFixture();

    await expect(
      operational.connect(attacker).transferETH(attacker.address, 1)
    ).to.be.reverted;
    await expect(
      operational.connect(attacker).transferERC20(ethers.ZeroAddress, attacker.address, 1)
    ).to.be.reverted;

    await expect(
      investment.connect(attacker).transferETH(attacker.address, 1)
    ).to.be.reverted;
    await expect(
      investment.connect(attacker).transferERC20(ethers.ZeroAddress, attacker.address, 1)
    ).to.be.reverted;

    await expect(
      reserve.connect(attacker).transferETH(attacker.address, 1)
    ).to.be.reverted;
    await expect(
      reserve.connect(attacker).transferERC20(ethers.ZeroAddress, attacker.address, 1)
    ).to.be.reverted;
  });

  it("enforces timelock delay and reverts premature execution", async function () {
    const { admin, voter1, voter2, recipient, governance, operational } = await deployFixture();

    await admin.sendTransaction({
      to: await operational.getAddress(),
      value: ethers.parseEther("2"),
    });

    const calldata = operational.interface.encodeFunctionData("transferETH", [
      recipient.address,
      ethers.parseEther("1"),
    ]);

    await governance.connect(admin).propose(
      0,
      await operational.getAddress(),
      0,
      calldata,
      "Operational payout"
    );
    const proposalId = await governance.proposalCount();

    await ethers.provider.send("hardhat_mine", ["0x2"]);

    await governance.connect(admin).castVote(proposalId, 1);
    await governance.connect(voter1).castVote(proposalId, 1);
    await governance.connect(voter2).castVote(proposalId, 0);

    await ethers.provider.send("hardhat_mine", ["0xb300"]);

    expect(await governance.state(proposalId)).to.equal(3n);

    await governance.connect(admin).queue(proposalId);

    await expect(governance.connect(admin).execute(proposalId)).to.be.reverted;
  });

  it("uses non-linear sqrt voting power in query and tally paths", async function () {
    const { admin, voter1, voter2, governance, votes, operational } = await deployFixture();

    const linearVotes = await votes.getVotes(admin.address);
    const expectedWeight = sqrtBigInt(linearVotes);
    const currentPower = await governance.currentVotingPower(admin.address);

    expect(currentPower).to.equal(expectedWeight);

    const calldata = operational.interface.encodeFunctionData("transferETH", [
      admin.address,
      1,
    ]);

    await governance.connect(admin).propose(
      0,
      await operational.getAddress(),
      0,
      calldata,
      "Validate sqrt voting weight"
    );
    const proposalId = await governance.proposalCount();

    await ethers.provider.send("hardhat_mine", ["0x2"]);

    const proposalSnapshot = (await ethers.provider.getBlockNumber()) - 1;
    const expectedCastWeight = sqrtBigInt(
      await votes.getPastVotes(admin.address, proposalSnapshot)
    );

    await expect(governance.connect(admin).castVote(proposalId, 1))
      .to.emit(governance, "VoteCast")
      .withArgs(admin.address, proposalId, 1, expectedCastWeight);

    await governance.connect(voter1).castVote(proposalId, 1);
    await governance.connect(voter2).castVote(proposalId, 0);
  });
});
