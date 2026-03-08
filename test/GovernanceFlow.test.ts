import { expect } from "chai";
import { ethers } from "hardhat";

describe("CryptoVentures DAO - Governance Flow", function () {
  async function deployFixture() {
    const [admin, voter1, voter2, guardian, recipient] = await ethers.getSigners();

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
    const guardianRole = await governance.GUARDIAN_ROLE();
    await governance.grantRole(governorRole, voter1.address);
    await governance.grantRole(governorRole, voter2.address);
    await governance.grantRole(guardianRole, guardian.address);

    await admin.sendTransaction({ to: await operational.getAddress(), value: ethers.parseEther("10") });
    await admin.sendTransaction({ to: await investment.getAddress(), value: ethers.parseEther("30") });
    await admin.sendTransaction({ to: await reserve.getAddress(), value: ethers.parseEther("60") });

    await governance.connect(admin).deposit({ value: ethers.parseEther("25") });
    await governance.connect(voter1).deposit({ value: ethers.parseEther("20") });
    await governance.connect(voter2).deposit({ value: ethers.parseEther("15") });

    await governance.connect(voter2).delegateVotingPower(voter1.address);

    return {
      admin,
      voter1,
      voter2,
      guardian,
      recipient,
      governance,
      votes,
      operational,
    };
  }

  it("runs proposal -> vote -> queue -> execute lifecycle", async function () {
    const { admin, voter1, recipient, governance, operational } = await deployFixture();

    const proposalAmount = ethers.parseEther("4");

    await governance.connect(admin).propose(0, recipient.address, proposalAmount, "Operational transfer");
    const proposalId = await governance.proposalCount();

    await ethers.provider.send("hardhat_mine", ["0x2"]);

    await governance.connect(admin).castVote(proposalId, 1);
    await governance.connect(voter1).castVote(proposalId, 1);

    await ethers.provider.send("hardhat_mine", ["0xb300"]);

    expect(await governance.state(proposalId)).to.equal(3n);

    const beforeBal = await ethers.provider.getBalance(await operational.getAddress());
    await governance.queue(proposalId);

    const config = await governance.getProposalTypeConfig(0);
    await ethers.provider.send("evm_increaseTime", [Number(config[2])]);
    await ethers.provider.send("evm_mine", []);

    await governance.execute(proposalId);

    const afterBal = await ethers.provider.getBalance(await operational.getAddress());
    expect(beforeBal - afterBal).to.equal(proposalAmount);
    expect(await governance.state(proposalId)).to.equal(5n);

    const receipt = await governance.getReceipt(proposalId, admin.address);
    expect(receipt.hasVoted).to.equal(true);
    expect(receipt.support).to.equal(1n);
  });

  it("defeats proposals with zero participation", async function () {
    const { admin, recipient, governance } = await deployFixture();

    await governance.connect(admin).propose(0, recipient.address, ethers.parseEther("1"), "No one votes");
    const proposalId = await governance.proposalCount();

    await ethers.provider.send("hardhat_mine", ["0xb302"]);

    expect(await governance.state(proposalId)).to.equal(2n);
  });

  it("defeats ties via approval threshold", async function () {
    const { admin, voter1, recipient, governance } = await deployFixture();

    await governance.connect(admin).propose(0, recipient.address, ethers.parseEther("1"), "Tie vote");
    const proposalId = await governance.proposalCount();

    await ethers.provider.send("hardhat_mine", ["0x2"]);
    await governance.connect(admin).castVote(proposalId, 1);
    await governance.connect(voter1).castVote(proposalId, 0);

    await ethers.provider.send("hardhat_mine", ["0xb300"]);
    expect(await governance.state(proposalId)).to.equal(2n);
  });

  it("enforces per-tier budget limits", async function () {
    const { admin, recipient, governance } = await deployFixture();

    const availableOperational = await governance.availableTierBudget(0);

    await expect(
      governance
        .connect(admin)
        .propose(0, recipient.address, availableOperational + 1n, "Over budget")
    ).to.be.revertedWith("Gov: exceeds tier budget");
  });

  it("allows guardian to cancel queued proposals", async function () {
    const { admin, voter1, guardian, recipient, governance } = await deployFixture();

    await governance.connect(admin).propose(0, recipient.address, ethers.parseEther("2"), "Cancelable");
    const proposalId = await governance.proposalCount();

    await ethers.provider.send("hardhat_mine", ["0x2"]);
    await governance.connect(admin).castVote(proposalId, 1);
    await governance.connect(voter1).castVote(proposalId, 1);

    await ethers.provider.send("hardhat_mine", ["0xb300"]);

    await governance.queue(proposalId);
    await governance.connect(guardian).cancel(proposalId);

    expect(await governance.state(proposalId)).to.equal(6n);
  });
});
