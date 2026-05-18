// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IAaveV3Pool
 * @notice minimal interface for Aave V3 Pool contract on Base
 * @dev only the methods Cauldron actually calls; full interface is much larger
 *      docs: https://aave.com/docs/aave-v3/smart-contracts
 */
interface IAaveV3Pool {
    /// @notice supply an asset to Aave, receive aToken in return
    /// @dev called via WrappedTokenGateway for ETH (which wraps to WETH first)
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice withdraw an asset from Aave by burning aToken
    /// @dev returns actual amount withdrawn (may be less than amount if insufficient liquidity)
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}
