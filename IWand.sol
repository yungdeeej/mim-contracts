// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IWand
 * @notice interface for the Wand router
 * @dev frontend-facing convenience contract; routes user calls through PoolManager → Cauldron
 */
interface IWand {
    // ─── Actions ───

    /// @notice cast MIM by depositing ETH
    /// @dev msg.value is the ETH amount; minOut protects against unexpected mint amounts
    function cast(uint256 minOut) external payable returns (uint256 mimMinted);

    /// @notice dispel MIM by burning it for ETH
    /// @dev Cauldron burns directly from the caller's balance (no approval to Wand needed)
    /// @param mimAmount the amount of MIM to burn
    /// @param minEthOut protects against unexpected returns
    function dispel(uint256 mimAmount, uint256 minEthOut) external returns (uint256 ethReturned);

    // ─── Reads ───

    function quoteCast(uint256 ethIn) external view returns (uint256 mimOut);
    function quoteDispel(uint256 mimIn) external view returns (uint256 ethOut);
}
