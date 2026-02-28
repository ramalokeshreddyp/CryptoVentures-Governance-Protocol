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
    /**
     * @notice Creates a proposal with executable action details
     * @param target Address to call during execution
     * @param value ETH value to send
     * @param data Calldata payload
     * @param description Human-readable proposal description
     */
    function propose(
        uint8 proposalType,
        address target,
        uint256 value,
        bytes calldata data,
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
}
