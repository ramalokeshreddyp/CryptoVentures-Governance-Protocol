// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./GovernanceVotes.sol";
import "./GovernanceTimelock.sol";

/**
 * @title GovernanceCore
 * @author CryptoVentures DAO
 * @notice Core DAO governance contract responsible for proposal lifecycle management
 *
 * @dev Implements:
 * - Snapshot-based voting using ERC20Votes
 * - Proposal threshold & quorum enforcement
 * - One-way proposal state transitions
 * - Role-based access control for governance actions
 *
 * Proposal Lifecycle:
 * Pending → Active → Succeeded → Queued → Executed
 *                    ↘ Defeated
 */
contract GovernanceCore is AccessControl {
    /*//////////////////////////////////////////////////////////////
                                ROLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Role required to create proposals, vote, and queue
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    /// @notice Role required to execute queued proposals
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    /// @notice Role required for emergency cancellation
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Minimum voting delay in blocks
    uint256 public constant MIN_VOTING_DELAY = 1;

    /// @notice Minimum voting period in blocks (~1 week at 12s/block)
    uint256 public constant MIN_VOTING_PERIOD = 45818;

    /// @notice Number of supported proposal types
    uint8 public constant PROPOSAL_TYPE_COUNT = 3;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Possible lifecycle states of a proposal
    enum ProposalState {
        Pending,
        Active,
        Defeated,
        Succeeded,
        Queued,
        Executed,
        Expired
    }

    /// @notice Governance proposal categories with type-specific rules
    enum ProposalType {
        Operational,
        Experimental,
        HighConviction
    }

    /// @notice Governance parameters specific to a proposal type
    struct ProposalTypeConfig {
        uint256 proposalThreshold;
        uint256 quorumBps;
        uint256 timelockDelay;
        uint256 approvalBps;
    }

    /// @notice Core proposal data stored on-chain
    struct Proposal {
        uint8 proposalType;
        address proposer;
        address target;
        uint256 value;
        bytes data;
        bytes32 descriptionHash;
        bytes32 operationId;
        uint256 snapshotBlock;
        uint256 deadlineBlock;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        uint256 eta;
        bool executed;
        bool queued;
        bool canceled;
    }

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice ERC20Votes-compatible governance token
    GovernanceVotes public immutable votesToken;

    /// @notice Timelock controller responsible for delayed execution
    GovernanceTimelock public immutable timelock;

    /// @notice Total number of proposals created
    uint256 public proposalCount;

    /// @notice Delay (in blocks) before voting becomes active
    uint256 public votingDelay;

    /// @notice Duration (in blocks) of the voting period
    uint256 public votingPeriod;

    /// @notice Mapping of proposal ID to proposal data
    mapping(uint256 => Proposal) private proposals;

    /// @notice Per-proposal-type governance settings
    mapping(uint8 => ProposalTypeConfig) private proposalTypeConfigs;

    /// @notice Treasury target per proposal category
    mapping(uint8 => address) public proposalTypeTreasury;

    /// @notice Tracks total executed ETH-value by proposal type
    mapping(uint8 => uint256) public executedValueByType;

    /// @notice Tracks whether an address has voted on a proposal
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a proposal is created
    event ProposalCreated(uint256 indexed proposalId);

    /// @notice Emitted when a vote is cast
    event VoteCast(
        address indexed voter,
        uint256 indexed proposalId,
        uint8 support,
        uint256 weight
    );

    /// @notice Emitted when a proposal is queued
    event ProposalQueued(uint256 indexed proposalId, uint256 eta);

    /// @notice Emitted when a proposal is executed
    event ProposalExecuted(uint256 indexed proposalId);

    /// @notice Emitted when a queued proposal is canceled by guardian
    event ProposalCanceled(uint256 indexed proposalId);

    /// @notice Emitted when proposal-type governance parameters are updated
    event ProposalTypeConfigUpdated(
        uint8 indexed proposalType,
        uint256 proposalThreshold,
        uint256 quorumBps,
        uint256 timelockDelay,
        uint256 approvalBps
    );

    /// @notice Emitted when proposal-type treasury target is updated
    event ProposalTypeTreasuryUpdated(uint8 indexed proposalType, address indexed treasury);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the governance system
     * @param _votesToken Address of the governance ERC20Votes token
    * @param _timelock Address of the governance timelock
     * @param admin Address granted admin & governor roles
     * @param _votingDelay Delay before voting starts (blocks)
     * @param _votingPeriod Duration of voting (blocks)
    * @param _quorumBps Base quorum threshold in basis points
    * @param _proposalThreshold Base minimum votes required to propose
     */
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
        require(_quorumBps <= 10_000, "Gov: quorum > 100%");
        require(_proposalThreshold > 0, "Gov: threshold zero");

        votesToken = _votesToken;
        timelock = _timelock;
        votingDelay = _votingDelay;
        votingPeriod = _votingPeriod;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
        _grantRole(EXECUTOR_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, admin);

        uint256 minDelay = _timelock.getMinDelay();
        uint256 experimentalThreshold = _proposalThreshold / 2;
        if (experimentalThreshold == 0) experimentalThreshold = 1;

        uint256 experimentalQuorum = _quorumBps / 2;
        if (experimentalQuorum == 0) experimentalQuorum = 1;

        uint256 highConvictionQuorum = _quorumBps * 2;
        if (highConvictionQuorum > 10_000) highConvictionQuorum = 10_000;

        _setProposalTypeConfig(
            uint8(ProposalType.Operational),
            _proposalThreshold,
            _quorumBps,
            minDelay,
            5001
        );
        _setProposalTypeConfig(
            uint8(ProposalType.Experimental),
            experimentalThreshold,
            experimentalQuorum,
            minDelay,
            5500
        );
        _setProposalTypeConfig(
            uint8(ProposalType.HighConviction),
            _proposalThreshold * 2,
            highConvictionQuorum,
            minDelay * 3,
            6000
        );
    }

    /*//////////////////////////////////////////////////////////////
                        PROPOSAL CREATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a new governance proposal
     * @dev Caller must meet proposal threshold based on snapshot voting power
     * @param target Target contract to call on execution
     * @param value ETH value to send with execution
     * @param data Calldata to send to the target
     * @param description Human-readable proposal description
     * @return proposalId Unique identifier of the created proposal
     */
    function propose(
        uint8 proposalType,
        address target,
        uint256 value,
        bytes calldata data,
        string calldata description
    )
        external
        onlyRole(GOVERNOR_ROLE)
        returns (uint256 proposalId)
    {
        require(_isValidProposalType(proposalType), "Gov: invalid proposal type");
        require(target != address(0), "Gov: target zero");
        require(
            proposalTypeTreasury[proposalType] == target,
            "Gov: invalid treasury for type"
        );

        ProposalTypeConfig storage config = proposalTypeConfigs[proposalType];

        uint256 proposerVotes = _nonLinearVotes(
            votesToken.getPastVotes(msg.sender, block.number - 1)
        );

        require(
            proposerVotes >= config.proposalThreshold,
            "Gov: proposer votes below threshold"
        );

        uint256 snapshot = block.number + votingDelay;
        uint256 deadline = snapshot + votingPeriod;
        bytes32 descriptionHash = keccak256(bytes(description));

        proposalCount++;
        Proposal storage proposal = proposals[proposalCount];
        proposal.proposalType = proposalType;
        proposal.proposer = msg.sender;
        proposal.target = target;
        proposal.value = value;
        proposal.data = data;
        proposal.descriptionHash = descriptionHash;
        proposal.snapshotBlock = snapshot;
        proposal.deadlineBlock = deadline;

        emit ProposalCreated(proposalCount);

        return proposalCount;
    }

    /*//////////////////////////////////////////////////////////////
                                VOTING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Casts a vote on an active proposal
     * @param proposalId ID of the proposal
     * @param support Vote choice (0 = Against, 1 = For, 2 = Abstain)
    * @dev Voting power is determined via ERC20Votes snapshot and transformed non-linearly
     */
    function castVote(uint256 proposalId, uint8 support)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        require(support <= 2, "Gov: invalid support");

        Proposal storage proposal = proposals[proposalId];

        require(state(proposalId) == ProposalState.Active, "Gov: voting closed");
        require(!hasVoted[proposalId][msg.sender], "Gov: already voted");

        uint256 weight = _nonLinearVotes(
            votesToken.getPastVotes(msg.sender, proposal.snapshotBlock)
        );

        require(weight > 0, "Gov: no voting power");

        hasVoted[proposalId][msg.sender] = true;

        if (support == 0) {
            proposal.againstVotes += weight;
        } else if (support == 1) {
            proposal.forVotes += weight;
        } else {
            proposal.abstainVotes += weight;
        }

        emit VoteCast(msg.sender, proposalId, support, weight);
    }

    /**
     * @notice Returns current non-linear voting power for an account
     * @param account Address to query
     */
    function currentVotingPower(address account)
        external
        view
        returns (uint256)
    {
        return _nonLinearVotes(votesToken.getVotes(account));
    }

    /**
     * @notice Returns snapshot non-linear voting power for an account
     * @param account Address to query
     * @param blockNumber Snapshot block number
     */
    function pastVotingPower(address account, uint256 blockNumber)
        external
        view
        returns (uint256)
    {
        return _nonLinearVotes(votesToken.getPastVotes(account, blockNumber));
    }

    /*//////////////////////////////////////////////////////////////
                          PROPOSAL STATE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the current state of a proposal
     * @param proposalId ID of the proposal
     */
    function state(uint256 proposalId)
        public
        view
        returns (ProposalState)
    {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.snapshotBlock != 0, "Gov: invalid proposal");

        if (proposal.executed) return ProposalState.Executed;
        if (proposal.queued) return ProposalState.Queued;
        if (block.number < proposal.snapshotBlock) return ProposalState.Pending;
        if (block.number <= proposal.deadlineBlock) return ProposalState.Active;

        uint256 totalSupplyAtSnapshot =
            votesToken.getPastTotalSupply(proposal.snapshotBlock);

        ProposalTypeConfig storage config = proposalTypeConfigs[proposal.proposalType];

        uint256 quorumVotes = Math.mulDiv(
            _nonLinearVotes(totalSupplyAtSnapshot),
            config.quorumBps,
            10_000
        );

        uint256 totalParticipating =
            proposal.forVotes +
            proposal.againstVotes +
            proposal.abstainVotes;

        if (totalParticipating < quorumVotes) {
            return ProposalState.Defeated;
        }

        uint256 sentimentVotes = proposal.forVotes + proposal.againstVotes;
        if (sentimentVotes == 0) {
            return ProposalState.Defeated;
        }

        uint256 approvalBps = Math.mulDiv(proposal.forVotes, 10_000, sentimentVotes);
        if (approvalBps < config.approvalBps) {
            return ProposalState.Defeated;
        }

        return ProposalState.Succeeded;
    }

    /*//////////////////////////////////////////////////////////////
                      QUEUE & EXECUTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Queues a succeeded proposal for execution
     * @param proposalId ID of the proposal
     */
    function queue(uint256 proposalId)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        Proposal storage proposal = proposals[proposalId];

        require(
            state(proposalId) == ProposalState.Succeeded,
            "Gov: proposal not succeeded"
        );
        require(!proposal.queued, "Gov: already queued");
        ProposalTypeConfig storage config = proposalTypeConfigs[proposal.proposalType];
        uint256 delay = config.timelockDelay;

        bytes32 operationId = timelock.hashOperation(
            proposal.target,
            proposal.value,
            proposal.data,
            bytes32(0),
            proposal.descriptionHash
        );

        timelock.schedule(
            proposal.target,
            proposal.value,
            proposal.data,
            bytes32(0),
            proposal.descriptionHash,
            delay
        );

        proposal.operationId = operationId;
        proposal.queued = true;
        proposal.eta = block.timestamp + delay;
        emit ProposalQueued(proposalId, proposal.eta);
    }

    /**
     * @notice Marks a queued proposal as executed
     * @param proposalId ID of the proposal
     */
    function execute(uint256 proposalId)
        external
        onlyRole(EXECUTOR_ROLE)
    {
        Proposal storage proposal = proposals[proposalId];

        require(
            state(proposalId) == ProposalState.Queued,
            "Gov: proposal not queued"
        );
        require(!proposal.canceled, "Gov: canceled proposal");

        timelock.execute(
            proposal.target,
            proposal.value,
            proposal.data,
            bytes32(0),
            proposal.descriptionHash
        );

        proposal.executed = true;
        executedValueByType[proposal.proposalType] += proposal.value;
        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Cancels a queued proposal in emergencies
     * @param proposalId ID of the proposal
     */
    function cancel(uint256 proposalId)
        external
        onlyRole(GUARDIAN_ROLE)
    {
        Proposal storage proposal = proposals[proposalId];

        require(proposal.snapshotBlock != 0, "Gov: invalid proposal");
        require(proposal.queued, "Gov: proposal not queued");
        require(!proposal.executed, "Gov: already executed");
        require(!proposal.canceled, "Gov: already canceled");

        timelock.cancel(proposal.operationId);

        proposal.canceled = true;
        proposal.queued = false;

        emit ProposalCanceled(proposalId);
    }

    /**
     * @notice Returns governance config for a proposal type
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
        return (
            config.proposalThreshold,
            config.quorumBps,
            config.timelockDelay,
            config.approvalBps
        );
    }

    /**
     * @notice Sets governance config for a proposal type
     */
    function setProposalTypeConfig(
        uint8 proposalType,
        uint256 typeProposalThreshold,
        uint256 typeQuorumBps,
        uint256 typeTimelockDelay,
        uint256 typeApprovalBps
    )
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setProposalTypeConfig(
            proposalType,
            typeProposalThreshold,
            typeQuorumBps,
            typeTimelockDelay,
            typeApprovalBps
        );
    }

    /**
     * @notice Sets allowed treasury target for a proposal type
     */
    function setProposalTypeTreasury(uint8 proposalType, address treasury)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_isValidProposalType(proposalType), "Gov: invalid proposal type");
        require(treasury != address(0), "Gov: treasury zero");

        proposalTypeTreasury[proposalType] = treasury;
        emit ProposalTypeTreasuryUpdated(proposalType, treasury);
    }

    function _setProposalTypeConfig(
        uint8 proposalType,
        uint256 typeProposalThreshold,
        uint256 typeQuorumBps,
        uint256 typeTimelockDelay,
        uint256 typeApprovalBps
    )
        internal
    {
        require(_isValidProposalType(proposalType), "Gov: invalid proposal type");
        require(typeProposalThreshold > 0, "Gov: threshold zero");
        require(typeQuorumBps <= 10_000, "Gov: quorum > 100%");
        require(typeTimelockDelay >= timelock.getMinDelay(), "Gov: delay below min");
        require(typeApprovalBps > 0 && typeApprovalBps <= 10_000, "Gov: invalid approval");

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

    function _isValidProposalType(uint8 proposalType)
        internal
        pure
        returns (bool)
    {
        return proposalType < PROPOSAL_TYPE_COUNT;
    }

    function _nonLinearVotes(uint256 linearVotes)
        internal
        pure
        returns (uint256)
    {
        return Math.sqrt(linearVotes);
    }
}
