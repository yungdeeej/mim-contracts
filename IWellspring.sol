// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IWellspring
 * @notice interface for the Wellspring yield distributor
 */
interface IWellspring {
    // ─── Structs ───

    struct MerkleRoot {
        bytes32 root;
        uint64 postedAtBlock;
        uint256 totalETHForThisRoot;
    }

    // ─── Keeper actions ───

    /// @notice post a new Merkle root for yield distribution
    /// @dev only callable by KEEPER, can be called many times across the protocol lifetime
    function postRoot(bytes32 root, uint256 totalETH) external;

    // ─── Deposits ───

    /// @notice accept ETH deposits to be distributed via Merkle roots
    /// @dev callable by anyone, primarily called by Cauldron during harvest
    function deposit() external payable;

    // ─── Claims ───

    /// @notice claim your share of yield against a specific Merkle root
    function claim(uint256 rootIndex, uint256 amount, bytes32[] calldata proof) external;

    /// @notice batch-claim across multiple roots in one transaction
    function claimMultiple(
        uint256[] calldata rootIndices,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;

    // ─── Reads ───

    function roots(uint256 index) external view returns (MerkleRoot memory);
    function rootCount() external view returns (uint256);
    function claimed(uint256 rootIndex, address holder) external view returns (bool);
    function totalETHReceived() external view returns (uint256);
    function totalETHClaimed() external view returns (uint256);
}
