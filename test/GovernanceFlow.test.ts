import { expect } from "chai";
import { ethers } from "hardhat";

describe("CryptoVentures DAO – Governance Flow", function () {
  async function deployFixture() {
    const [admin, voter1, voter2, recipient] = await ethers.getSigners();

    /* ---------------- GovernanceVotes ---------------- */
    const Votes = await ethers.getContractFactory("GovernanceVotes");
    const votes = await Votes.deploy(
      "CryptoVentures DAO",
      "CVDAO",
      admin.address
    );
    await votes.waitForDeployment();

    /* ---------------- Timelock ---------------- */
    const minDelay = 2 * 24 * 60 * 60;

    const Timelock = await ethers.getContractFactory("GovernanceTimelock");
    const timelock = await Timelock.deploy(
      minDelay,
      [admin.address],
      [admin.address],
      admin.address
    );
    await timelock.waitForDeployment();

    /* ---------------- GovernanceCore ---------------- */
    const votingDelay = 1;
    const votingPeriod = 45818; // shortened for tests
    const quorumBps = 2000; // 20%
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
    const EXECUTOR_ROLE = await timelock.EXECUTOR_ROLE();

    await timelock.grantRole(PROPOSER_ROLE, await governance.getAddress());
    await timelock.grantRole(EXECUTOR_ROLE, await governance.getAddress());

    /* ---------------- Treasury ---------------- */
    const Operational = await ethers.getContractFactory("OperationalTreasury");
    const treasury = await Operational.deploy(
      await timelock.getAddress(),
      ethers.parseEther("10")
    );
    await treasury.waitForDeployment();

    await governance.setProposalTypeTreasury(0, await treasury.getAddress());
    await governance.setProposalTypeTreasury(1, await treasury.getAddress());
    await governance.setProposalTypeTreasury(2, await treasury.getAddress());
    /* ---------------- Grant governor role to voters ---------------- */
    const GOVERNOR_ROLE = await governance.GOVERNOR_ROLE();

    await governance.grantRole(GOVERNOR_ROLE, voter1.address);
    await governance.grantRole(GOVERNOR_ROLE, voter2.address);


    /* ---------------- Mint voting power ---------------- */
    await votes.mint(admin.address, ethers.parseEther("200"));
    await votes.mint(voter1.address, ethers.parseEther("100"));
    await votes.mint(voter2.address, ethers.parseEther("100"));

  /* ---------------- Delegate voting power ---------------- */
  await votes.connect(admin).delegate(admin.address);
  await votes.connect(voter1).delegate(voter1.address);
  await votes.connect(voter2).delegate(voter2.address);

  /* ---------------- Snapshot block ---------------- */
  await ethers.provider.send("evm_mine", []);

    return {
      admin,
      voter1,
      voter2,
      recipient,
      votes,
      governance,
      timelock,
      treasury,
    };
  }

  it("runs full proposal → vote → queue → execute flow", async function () {
    const {
      admin,
      voter1,
      voter2,
      recipient,
      governance,
      timelock,
      treasury,
    } = await deployFixture();

    const transferAmount = ethers.parseEther("1");
    await admin.sendTransaction({
      to: await treasury.getAddress(),
      value: ethers.parseEther("5"),
    });

    const transferCalldata = treasury.interface.encodeFunctionData("transferETH", [
      recipient.address,
      transferAmount,
    ]);

    /* ---------------- Propose ---------------- */
    await governance.connect(admin).propose(
      0,
      await treasury.getAddress(),
      0,
      transferCalldata,
      "Transfer ETH from treasury"
    );
    const proposalId = await governance.proposalCount();

    /* ---------------- Move to voting ---------------- */
    await ethers.provider.send("hardhat_mine", ["0x2"]);

    /* ---------------- Vote ---------------- */
    await governance.connect(admin).castVote(proposalId, 1);
    await governance.connect(voter1).castVote(proposalId, 1);
    await governance.connect(voter2).castVote(proposalId, 0);

    /* ---------------- End voting ---------------- */
    await ethers.provider.send("hardhat_mine", ["0xb300"]);


    expect(await governance.state(proposalId)).to.equal(3); // Succeeded

    /* ---------------- Queue ---------------- */
    await governance.queue(proposalId);
    expect(await governance.state(proposalId)).to.equal(4); // Queued

    /* ---------------- Wait timelock ---------------- */
    const config = await governance.getProposalTypeConfig(0);
    await ethers.provider.send("evm_increaseTime", [Number(config[2])]);
    await ethers.provider.send("evm_mine", []);

    /* ---------------- Execute ---------------- */
    const treasuryBalanceBefore = await ethers.provider.getBalance(
      await treasury.getAddress()
    );

    await governance.execute(proposalId);
    expect(await governance.state(proposalId)).to.equal(5); // Executed

    const treasuryBalanceAfter = await ethers.provider.getBalance(
      await treasury.getAddress()
    );

    expect(treasuryBalanceBefore - treasuryBalanceAfter).to.equal(transferAmount);
  });

  it("prevents double voting", async function () {
    const { admin, governance, treasury } = await deployFixture();

    const noopCalldata = treasury.interface.encodeFunctionData("transferETH", [
      admin.address,
      1,
    ]);

    await governance.connect(admin).propose(
      0,
      await treasury.getAddress(),
      0,
      noopCalldata,
      "Double vote prevention"
    );
    const proposalId = await governance.proposalCount();

    await ethers.provider.send("hardhat_mine", ["0x2"]);

    await governance.connect(admin).castVote(proposalId, 1);

    await expect(
      governance.connect(admin).castVote(proposalId, 1)
    ).to.be.revertedWith("Gov: already voted");
  });
});
