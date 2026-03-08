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

describe("CryptoVentures DAO - Security Regression", function () {
  async function deployFixture() {
    const [admin, voter1, voter2, attacker, recipient] = await ethers.getSigners();

    const Votes = await ethers.getContractFactory("GovernanceVotes");
    const votes = await Votes.deploy("CryptoVentures DAO", "CVDAO", admin.address);
    await votes.waitForDeployment();

    const Timelock = await ethers.getContractFactory("GovernanceTimelock");
    const timelock = await Timelock.deploy(
      2 * 24 * 60 * 60,
      [admin.address],
      [admin.address],
      admin.address
    );
    await timelock.waitForDeployment();

    const Gov = await ethers.getContractFactory("GovernanceCore");
    const governance = await Gov.deploy(
      await votes.getAddress(),
      await timelock.getAddress(),
      admin.address,
      1,
      45818,
      2000,
      1n
    );
    await governance.waitForDeployment();

    const tokenGovernorRole = await votes.GOVERNOR_ROLE();
    await votes.grantRole(tokenGovernorRole, await governance.getAddress());

    const proposerRole = await timelock.PROPOSER_ROLE();
    const timelockExecutorRole = await timelock.EXECUTOR_ROLE();
    const cancellerRole = await timelock.CANCELLER_ROLE();
    await timelock.grantRole(proposerRole, await governance.getAddress());
    await timelock.grantRole(timelockExecutorRole, await governance.getAddress());
    await timelock.grantRole(cancellerRole, await governance.getAddress());

    const Operational = await ethers.getContractFactory("OperationalTreasury");
    const operational = await Operational.deploy(await timelock.getAddress(), ethers.parseEther("10"));
    await operational.waitForDeployment();

    const Investment = await ethers.getContractFactory("InvestmentTreasury");
    const investment = await Investment.deploy(await timelock.getAddress(), ethers.parseEther("100"));
    await investment.waitForDeployment();

    const Reserve = await ethers.getContractFactory("ReserveTreasury");
    const reserve = await Reserve.deploy(await timelock.getAddress());
    await reserve.waitForDeployment();

    await governance.setProposalTypeTreasury(0, await operational.getAddress());
    await governance.setProposalTypeTreasury(1, await investment.getAddress());
    await governance.setProposalTypeTreasury(2, await reserve.getAddress());

    const governorRole = await governance.GOVERNOR_ROLE();
    await governance.grantRole(governorRole, voter1.address);
    await governance.grantRole(governorRole, voter2.address);

    await admin.sendTransaction({ to: await operational.getAddress(), value: ethers.parseEther("1") });
    await admin.sendTransaction({ to: await investment.getAddress(), value: ethers.parseEther("3") });
    await admin.sendTransaction({ to: await reserve.getAddress(), value: ethers.parseEther("6") });

    await governance.connect(admin).deposit({ value: ethers.parseEther("30") });
    await governance.connect(voter1).deposit({ value: ethers.parseEther("20") });
    await governance.connect(voter2).deposit({ value: ethers.parseEther("15") });

    return {
      admin,
      voter1,
      voter2,
      attacker,
      recipient,
      votes,
      governance,
      operational,
      investment,
      reserve,
    };
  }

  async function createAndPassOperationalProposal(
    governance: any,
    admin: any,
    voter1: any,
    recipient: any,
    amount: bigint
  ) {
    await governance.connect(admin).propose(0, recipient.address, amount, "Operational payout");
    const proposalId = await governance.proposalCount();

    await ethers.provider.send("hardhat_mine", ["0x2"]);
    await governance.connect(admin).castVote(proposalId, 1);
    await governance.connect(voter1).castVote(proposalId, 1);
    await ethers.provider.send("hardhat_mine", ["0xb300"]);

    return proposalId;
  }

  it("rejects unauthorized treasury transfer entrypoints", async function () {
    const { attacker, operational, investment, reserve } = await deployFixture();

    await expect(operational.connect(attacker).transferETH(attacker.address, 1)).to.be.reverted;
    await expect(
      operational.connect(attacker).transferERC20(ethers.ZeroAddress, attacker.address, 1)
    ).to.be.reverted;

    await expect(investment.connect(attacker).transferETH(attacker.address, 1)).to.be.reverted;
    await expect(
      investment.connect(attacker).transferERC20(ethers.ZeroAddress, attacker.address, 1)
    ).to.be.reverted;

    await expect(reserve.connect(attacker).transferETH(attacker.address, 1)).to.be.reverted;
    await expect(
      reserve.connect(attacker).transferERC20(ethers.ZeroAddress, attacker.address, 1)
    ).to.be.reverted;
  });

  it("enforces timelock and rejects premature execution", async function () {
    const { admin, voter1, recipient, governance } = await deployFixture();

    const proposalId = await createAndPassOperationalProposal(
      governance,
      admin,
      voter1,
      recipient,
      ethers.parseEther("0.5")
    );

    await governance.queue(proposalId);
    await expect(governance.execute(proposalId)).to.be.revertedWith("TimelockController: operation is not ready");
  });

  it("uses non-linear sqrt voting power in query path", async function () {
    const { admin, governance, votes } = await deployFixture();

    const linearVotes = await votes.getVotes(admin.address);
    const expected = sqrtBigInt(linearVotes);

    expect(await governance.currentVotingPower(admin.address)).to.equal(expected);
  });

  it("prevents queue when treasury balance is insufficient", async function () {
    const { admin, voter1, recipient, governance, operational } = await deployFixture();

    // Drain operational treasury directly from timelock context is impossible in test setup,
    // so we only fund 0 by deploying a proposal amount beyond balance.
    await governance.connect(admin).propose(0, recipient.address, ethers.parseEther("2"), "Too much");
    const proposalId = await governance.proposalCount();

    await ethers.provider.send("hardhat_mine", ["0x2"]);
    await governance.connect(admin).castVote(proposalId, 1);
    await governance.connect(voter1).castVote(proposalId, 1);
    await ethers.provider.send("hardhat_mine", ["0xb300"]);

    expect(await ethers.provider.getBalance(await operational.getAddress())).to.equal(
      ethers.parseEther("1")
    );

    await expect(governance.queue(proposalId)).to.be.revertedWith("Gov: treasury insufficient ETH");
  });

  it("marks queued proposals as expired after grace window", async function () {
    const { admin, voter1, recipient, governance } = await deployFixture();

    const proposalId = await createAndPassOperationalProposal(
      governance,
      admin,
      voter1,
      recipient,
      ethers.parseEther("1")
    );

    await governance.queue(proposalId);

    const proposal = await governance.getProposal(proposalId);
    const grace = await governance.executionGracePeriod();
    const nowTs = (await ethers.provider.getBlock("latest"))!.timestamp;
    const forward = Number(proposal.eta + grace - BigInt(nowTs) + 5n);

    await ethers.provider.send("evm_increaseTime", [forward]);
    await ethers.provider.send("evm_mine", []);

    expect(await governance.state(proposalId)).to.equal(7n);

    await governance.releaseExpiredReservation(proposalId);

    const postRelease = await governance.getProposal(proposalId);
    expect(postRelease.queued).to.equal(false);
  });
});
