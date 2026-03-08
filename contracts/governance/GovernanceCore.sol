// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./GovernanceVotes.sol";
import "./GovernanceTimelock.sol";

/**
 * @title GovernanceCore
 * @author CryptoVentures DAO
 * @notice Core DAO governance contract for stake deposits, voting, timelock queueing, and treasury execution.
 */
contract GovernanceCore is AccessControl {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 public constant MIN_VOTING_DELAY = 1;
    uint256 public constant MIN_VOTING_PERIOD = 45818;
    uint256 public constant MAX_BPS = 10_000;
    uint8 public constant PROPOSAL_TYPE_COUNT = 3;

    enum ProposalState {
        Pending,
        Active,
        Defeated,
        Succeeded,
        Queued,
        Executed,
        Canceled,
        Expired
    }

    enum ProposalType {
        Operational,
        Experimental,
        HighConviction
    }

    struct ProposalTypeConfig {
        uint256 proposalThreshold;
        uint256 quorumBps;
        uint256 timelockDelay;
        uint256 approvalBps;
    }

    struct Proposal {
        uint8 proposalType;
        address proposer;
        address treasury;
        address recipient;
        uint256 amount;
        bytes32 descriptionHash;
        bytes32 operationId;
        uint256 snapshotBlock;
        uint256 deadlineBlock;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        uint256 eta;
        bool queued;
        bool executed;
        bool canceled;
        bool reservationCleared;
    }

    struct Receipt {
        bool hasVoted;
        uint8 support;
        uint256 votes;
    }

    GovernanceVotes public immutable votesToken;
    GovernanceTimelock public immutable timelock;

    uint256 public proposalCount;
    uint256 public votingDelay;
    uint256 public votingPeriod;
    uint256 public executionGracePeriod;

    uint256 public totalDepositedETH;

    mapping(uint256 => Proposal) private proposals;
    mapping(uint256 => mapping(address => Receipt)) private receipts;

    mapping(uint8 => ProposalTypeConfig) private proposalTypeConfigs;
    mapping(uint8 => address) public proposalTypeTreasury;

    mapping(uint8 => uint16) public allocationBpsByType;
    mapping(uint8 => uint256) public queuedValueByType;
    mapping(uint8 => uint256) public executedValueByType;

    mapping(address => uint256) public depositedByMember;

    event Deposited(address indexed member, uint256 amount, uint256 mintedVotes);
    event DelegationChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        uint8 indexed proposalType,
        address treasury,
        address recipient,
        uint256 amount,
        string description
    );

    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        uint8 support,
        uint256 weight
    );

    event ProposalQueued(uint256 indexed proposalId, uint256 eta);
    event ProposalExecuted(uint256 indexed proposalId, address indexed recipient, uint256 amount);
    event ProposalCanceled(uint256 indexed proposalId);
    event ProposalReservationReleased(uint256 indexed proposalId);

    event ProposalTypeConfigUpdated(
        uint8 indexed proposalType,
        uint256 proposalThreshold,
        uint256 quorumBps,
        uint256 timelockDelay,
        uint256 approvalBps
    );

    event ProposalTypeTreasuryUpdated(uint8 indexed proposalType, address indexed treasury);
    event AllocationBpsUpdated(uint8 indexed proposalType, uint16 allocationBps);

    constructor(
        GovernanceVotes _votesToken,
        GovernanceTimelock _timelock,
        address admin,
        uint256 _votingDelay,
        uint256 _votingPeriod,
        uint256 _quorumBps,
        uint256 _proposalThreshold
    ) {
        require(address(_votesToken) != address(0), "Gov: votes token zero");
        require(address(_timelock) != address(0), "Gov: timelock zero");
        require(admin != address(0), "Gov: admin zero");
        require(_votingDelay >= MIN_VOTING_DELAY, "Gov: voting delay too short");
        require(_votingPeriod >= MIN_VOTING_PERIOD, "Gov: voting period too short");
        require(_quorumBps <= MAX_BPS, "Gov: quorum > 100%");
        require(_proposalThreshold > 0, "Gov: threshold zero");

        votesToken = _votesToken;
        timelock = _timelock;
        votingDelay = _votingDelay;
        votingPeriod = _votingPeriod;
        executionGracePeriod = 7 days;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
        _grantRole(EXECUTOR_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, admin);

        uint256 minDelay = _timelock.getMinDelay();
        uint256 operationalDelay = minDelay > 1 days ? minDelay : 1 days;
        uint256 experimentalDelay = minDelay > 3 days ? minDelay : 3 days;
        uint256 highConvictionDelay = minDelay > 7 days ? minDelay : 7 days;

        _setProposalTypeConfig(
            uint8(ProposalType.Operational),
            _proposalThreshold,
            1500,
            operationalDelay,
            5000
        );
        _setProposalTypeConfig(
            uint8(ProposalType.Experimental),
            _proposalThreshold,
            2500,
            experimentalDelay,
            5000
        );
        _setProposalTypeConfig(
            uint8(ProposalType.HighConviction),
            _proposalThreshold,
            4000,
            highConvictionDelay,
            6000
        );

        allocationBpsByType[uint8(ProposalType.HighConviction)] = 6000;
        allocationBpsByType[uint8(ProposalType.Experimental)] = 3000;
        allocationBpsByType[uint8(ProposalType.Operational)] = 1000;
    }

    /**
     * @notice Deposits ETH into governance and mints 1:1 governance stake units.
     * @dev Minted tokens are self-delegated for immediate governance participation.
     */
    function deposit() external payable onlyRole(GOVERNOR_ROLE) {
        require(msg.value > 0, "Gov: zero deposit");

        depositedByMember[msg.sender] += msg.value;
        totalDepositedETH += msg.value;

        votesToken.mint(msg.sender, msg.value);

        if (votesToken.delegates(msg.sender) == address(0)) {
            votesToken.delegateFor(msg.sender, msg.sender);
            emit DelegationChanged(msg.sender, address(0), msg.sender);
        }

        emit Deposited(msg.sender, msg.value, msg.value);
    }

    /**
     * @notice Delegates voting power to a trusted member.
     * @param delegatee Address receiving delegated power.
     */
    function delegateVotingPower(address delegatee) external onlyRole(GOVERNOR_ROLE) {
        require(delegatee != address(0), "Gov: delegate zero");

        address fromDelegate = votesToken.delegates(msg.sender);
        votesToken.delegateFor(msg.sender, delegatee);

        emit DelegationChanged(msg.sender, fromDelegate, delegatee);
    }

    /**
     * @notice Revokes external delegation by self-delegating.
     */
    function undelegateVotingPower() external onlyRole(GOVERNOR_ROLE) {
        address fromDelegate = votesToken.delegates(msg.sender);
        votesToken.delegateFor(msg.sender, msg.sender);
        emit DelegationChanged(msg.sender, fromDelegate, msg.sender);
    }

    /**
     * @notice Creates an ETH transfer proposal against the treasury bound to a proposal type.
     */
    function propose(
        uint8 proposalType,
        address recipient,
        uint256 amount,
        string calldata description
    ) external onlyRole(GOVERNOR_ROLE) returns (uint256 proposalId) {
        require(_isValidProposalType(proposalType), "Gov: invalid proposal type");
        require(recipient != address(0), "Gov: recipient zero");
        require(amount > 0, "Gov: amount zero");

        address treasury = proposalTypeTreasury[proposalType];
        require(treasury != address(0), "Gov: treasury not set");
        require(amount <= availableTierBudget(proposalType), "Gov: exceeds tier budget");

        ProposalTypeConfig storage config = proposalTypeConfigs[proposalType];

        uint256 proposerVotes = _nonLinearVotes(votesToken.getPastVotes(msg.sender, block.number - 1));
        require(proposerVotes >= config.proposalThreshold, "Gov: proposer votes below threshold");

        proposalId = ++proposalCount;

        Proposal storage proposal = proposals[proposalId];
        proposal.proposalType = proposalType;
        proposal.proposer = msg.sender;
        proposal.treasury = treasury;
        proposal.recipient = recipient;
        proposal.amount = amount;
        proposal.descriptionHash = keccak256(bytes(description));
        proposal.snapshotBlock = block.number + votingDelay;
        proposal.deadlineBlock = proposal.snapshotBlock + votingPeriod;

        emit ProposalCreated(
            proposalId,
            msg.sender,
            proposalType,
            treasury,
            recipient,
            amount,
            description
        );
    }

    /**
     * @notice Casts one immutable vote per proposal.
     */
    function castVote(uint256 proposalId, uint8 support) external onlyRole(GOVERNOR_ROLE) {
        require(support <= 2, "Gov: invalid support");
        require(state(proposalId) == ProposalState.Active, "Gov: voting closed");

        Receipt storage receipt = receipts[proposalId][msg.sender];
        require(!receipt.hasVoted, "Gov: already voted");

        Proposal storage proposal = proposals[proposalId];
        uint256 weight = _nonLinearVotes(votesToken.getPastVotes(msg.sender, proposal.snapshotBlock));
        require(weight > 0, "Gov: no voting power");

        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = weight;

        if (support == 0) {
            proposal.againstVotes += weight;
        } else if (support == 1) {
            proposal.forVotes += weight;
        } else {
            proposal.abstainVotes += weight;
        }

        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    /**
     * @notice Returns current non-linear voting power.
     */
    function currentVotingPower(address account) external view returns (uint256) {
        return _nonLinearVotes(votesToken.getVotes(account));
    }

    /**
     * @notice Returns snapshot non-linear voting power.
     */
    function pastVotingPower(address account, uint256 blockNumber) external view returns (uint256) {
        return _nonLinearVotes(votesToken.getPastVotes(account, blockNumber));
    }

    /**
     * @notice Returns a proposal's vote receipt for a specific voter.
     */
    function getReceipt(uint256 proposalId, address voter) external view returns (Receipt memory) {
        return receipts[proposalId][voter];
    }

    /**
     * @notice Returns full proposal details.
     */
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.snapshotBlock != 0, "Gov: invalid proposal");
        return proposal;
    }

    /**
     * @notice Returns true if proposal reached quorum and approval thresholds.
     */
    function hasSucceeded(uint256 proposalId) public view returns (bool) {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.snapshotBlock != 0, "Gov: invalid proposal");

        uint256 totalSupplyAtSnapshot = votesToken.getPastTotalSupply(proposal.snapshotBlock);
        ProposalTypeConfig storage config = proposalTypeConfigs[proposal.proposalType];

        uint256 quorumVotes = Math.mulDiv(_nonLinearVotes(totalSupplyAtSnapshot), config.quorumBps, MAX_BPS);
        uint256 totalParticipating = proposal.forVotes + proposal.againstVotes + proposal.abstainVotes;

        if (totalParticipating < quorumVotes) {
            return false;
        }

        uint256 sentimentVotes = proposal.forVotes + proposal.againstVotes;
        if (sentimentVotes == 0) {
            return false;
        }

        uint256 approvalBps = Math.mulDiv(proposal.forVotes, MAX_BPS, sentimentVotes);
        return approvalBps >= config.approvalBps;
    }

    /**
     * @notice Returns current state for a proposal ID.
     */
    function state(uint256 proposalId) public view returns (ProposalState) {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.snapshotBlock != 0, "Gov: invalid proposal");

        if (proposal.executed) return ProposalState.Executed;
        if (proposal.canceled) return ProposalState.Canceled;

        if (proposal.queued) {
            if (block.timestamp > proposal.eta + executionGracePeriod) {
                return ProposalState.Expired;
            }
            return ProposalState.Queued;
        }

        if (block.number < proposal.snapshotBlock) return ProposalState.Pending;
        if (block.number <= proposal.deadlineBlock) return ProposalState.Active;

        if (!hasSucceeded(proposalId)) {
            return ProposalState.Defeated;
        }

        return ProposalState.Succeeded;
    }

    /**
     * @notice Queues a succeeded proposal in the timelock.
     */
    function queue(uint256 proposalId) external onlyRole(GOVERNOR_ROLE) {
        Proposal storage proposal = proposals[proposalId];

        require(state(proposalId) == ProposalState.Succeeded, "Gov: proposal not succeeded");
        require(address(proposal.treasury).balance >= proposal.amount, "Gov: treasury insufficient ETH");

        ProposalTypeConfig storage config = proposalTypeConfigs[proposal.proposalType];

        bytes memory callData = abi.encodeWithSignature(
            "transferETH(address,uint256)",
            proposal.recipient,
            proposal.amount
        );

        bytes32 operationId = timelock.hashOperation(
            proposal.treasury,
            0,
            callData,
            bytes32(0),
            proposal.descriptionHash
        );

        timelock.schedule(
            proposal.treasury,
            0,
            callData,
            bytes32(0),
            proposal.descriptionHash,
            config.timelockDelay
        );

        proposal.operationId = operationId;
        proposal.queued = true;
        proposal.eta = block.timestamp + config.timelockDelay;

        queuedValueByType[proposal.proposalType] += proposal.amount;

        emit ProposalQueued(proposalId, proposal.eta);
    }

    /**
     * @notice Executes a queued proposal after timelock delay and before grace expiry.
     */
    function execute(uint256 proposalId) external onlyRole(EXECUTOR_ROLE) {
        Proposal storage proposal = proposals[proposalId];

        require(state(proposalId) == ProposalState.Queued, "Gov: proposal not executable");

        bytes memory callData = abi.encodeWithSignature(
            "transferETH(address,uint256)",
            proposal.recipient,
            proposal.amount
        );

        timelock.execute(
            proposal.treasury,
            0,
            callData,
            bytes32(0),
            proposal.descriptionHash
        );

        proposal.executed = true;
        proposal.queued = false;

        if (!proposal.reservationCleared) {
            proposal.reservationCleared = true;
            queuedValueByType[proposal.proposalType] -= proposal.amount;
            executedValueByType[proposal.proposalType] += proposal.amount;
        }

        emit ProposalExecuted(proposalId, proposal.recipient, proposal.amount);
    }

    /**
     * @notice Cancels a queued proposal in emergency conditions.
     */
    function cancel(uint256 proposalId) external onlyRole(GUARDIAN_ROLE) {
        Proposal storage proposal = proposals[proposalId];

        require(proposal.snapshotBlock != 0, "Gov: invalid proposal");
        require(proposal.queued, "Gov: proposal not queued");
        require(!proposal.executed, "Gov: already executed");
        require(!proposal.canceled, "Gov: already canceled");

        timelock.cancel(proposal.operationId);

        proposal.canceled = true;
        proposal.queued = false;

        if (!proposal.reservationCleared) {
            proposal.reservationCleared = true;
            queuedValueByType[proposal.proposalType] -= proposal.amount;
        }

        emit ProposalCanceled(proposalId);
    }

    /**
     * @notice Releases reserved budget from an expired proposal.
     */
    function releaseExpiredReservation(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];

        require(state(proposalId) == ProposalState.Expired, "Gov: proposal not expired");
        require(!proposal.reservationCleared, "Gov: reservation cleared");

        proposal.reservationCleared = true;
        proposal.queued = false;
        queuedValueByType[proposal.proposalType] -= proposal.amount;

        emit ProposalReservationReleased(proposalId);
    }

    /**
     * @notice Returns governance config for a proposal type.
     */
    function getProposalTypeConfig(uint8 proposalType)
        external
        view
        returns (
            uint256 typeProposalThreshold,
            uint256 typeQuorumBps,
            uint256 typeTimelockDelay,
            uint256 typeApprovalBps
        )
    {
        require(_isValidProposalType(proposalType), "Gov: invalid proposal type");
        ProposalTypeConfig storage config = proposalTypeConfigs[proposalType];
        return (config.proposalThreshold, config.quorumBps, config.timelockDelay, config.approvalBps);
    }

    /**
     * @notice Updates governance config for a proposal type.
     */
    function setProposalTypeConfig(
        uint8 proposalType,
        uint256 typeProposalThreshold,
        uint256 typeQuorumBps,
        uint256 typeTimelockDelay,
        uint256 typeApprovalBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setProposalTypeConfig(
            proposalType,
            typeProposalThreshold,
            typeQuorumBps,
            typeTimelockDelay,
            typeApprovalBps
        );
    }

    /**
     * @notice Binds treasury address to a proposal type.
     */
    function setProposalTypeTreasury(uint8 proposalType, address treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_isValidProposalType(proposalType), "Gov: invalid proposal type");
        require(treasury != address(0), "Gov: treasury zero");

        proposalTypeTreasury[proposalType] = treasury;
        emit ProposalTypeTreasuryUpdated(proposalType, treasury);
    }

    /**
     * @notice Updates allocation basis points per proposal type.
     */
    function setAllocationBps(uint8 proposalType, uint16 allocationBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_isValidProposalType(proposalType), "Gov: invalid proposal type");
        require(allocationBps <= MAX_BPS, "Gov: allocation > 100%");

        uint256 newTotal =
            allocationBpsByType[0] +
            allocationBpsByType[1] +
            allocationBpsByType[2] -
            allocationBpsByType[proposalType] +
            allocationBps;

        require(newTotal == MAX_BPS, "Gov: allocation sum != 100%");

        allocationBpsByType[proposalType] = allocationBps;
        emit AllocationBpsUpdated(proposalType, allocationBps);
    }

    /**
     * @notice Updates the grace window for queued proposal execution.
     */
    function setExecutionGracePeriod(uint256 newGracePeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newGracePeriod > 0, "Gov: grace zero");
        executionGracePeriod = newGracePeriod;
    }

    /**
     * @notice Returns total budget assigned to a proposal tier.
     */
    function tierBudget(uint8 proposalType) public view returns (uint256) {
        require(_isValidProposalType(proposalType), "Gov: invalid proposal type");
        return Math.mulDiv(totalDepositedETH, allocationBpsByType[proposalType], MAX_BPS);
    }

    /**
     * @notice Returns available budget for new proposals in a proposal tier.
     */
    function availableTierBudget(uint8 proposalType) public view returns (uint256) {
        uint256 budget = tierBudget(proposalType);
        uint256 consumed = queuedValueByType[proposalType] + executedValueByType[proposalType];
        if (consumed >= budget) {
            return 0;
        }
        return budget - consumed;
    }

    function _setProposalTypeConfig(
        uint8 proposalType,
        uint256 typeProposalThreshold,
        uint256 typeQuorumBps,
        uint256 typeTimelockDelay,
        uint256 typeApprovalBps
    ) internal {
        require(_isValidProposalType(proposalType), "Gov: invalid proposal type");
        require(typeProposalThreshold > 0, "Gov: threshold zero");
        require(typeQuorumBps <= MAX_BPS, "Gov: quorum > 100%");
        require(typeTimelockDelay >= timelock.getMinDelay(), "Gov: delay below min");
        require(typeApprovalBps > 0 && typeApprovalBps <= MAX_BPS, "Gov: invalid approval");

        proposalTypeConfigs[proposalType] = ProposalTypeConfig({
            proposalThreshold: typeProposalThreshold,
            quorumBps: typeQuorumBps,
            timelockDelay: typeTimelockDelay,
            approvalBps: typeApprovalBps
        });

        emit ProposalTypeConfigUpdated(
            proposalType,
            typeProposalThreshold,
            typeQuorumBps,
            typeTimelockDelay,
            typeApprovalBps
        );
    }

    function _isValidProposalType(uint8 proposalType) internal pure returns (bool) {
        return proposalType < PROPOSAL_TYPE_COUNT;
    }

    function _nonLinearVotes(uint256 linearVotes) internal pure returns (uint256) {
        return Math.sqrt(linearVotes);
    }
}
