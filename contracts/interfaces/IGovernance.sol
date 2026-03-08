// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IGovernance
 * @author CryptoVentures DAO
 * @notice Interface for core governance actions
 *
 * @dev Used by treasury contracts to interact with GovernanceCore
 */
interface IGovernance {
    function deposit() external payable;

    function delegateVotingPower(address delegatee) external;

    function undelegateVotingPower() external;

    /**
     * @notice Creates an ETH transfer proposal by proposal type
     * @param recipient Recipient of treasury funds
     * @param amount Amount of ETH to transfer
     * @param description Human-readable proposal description
     */
    function propose(
        uint8 proposalType,
        address recipient,
        uint256 amount,
        string calldata description
    ) external returns (uint256);

    /**
     * @notice Returns the current state of a proposal
     * @param proposalId The proposal identifier
     */
    function state(uint256 proposalId) external view returns (uint8);

    /**
     * @notice Queues a succeeded proposal
     * @param proposalId The proposal identifier
     */
    function queue(uint256 proposalId) external;

    /**
     * @notice Executes a queued proposal
     * @param proposalId The proposal identifier
     */
    function execute(uint256 proposalId) external;

    function currentVotingPower(address account) external view returns (uint256);
}
