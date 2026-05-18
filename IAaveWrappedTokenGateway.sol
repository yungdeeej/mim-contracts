// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IAaveWrappedTokenGateway
 * @notice Aave's helper contract for depositing/withdrawing ETH (vs WETH) directly
 * @dev wraps ETH to WETH on deposit, unwraps WETH to ETH on withdraw
 *      docs: https://aave.com/docs/aave-v3/smart-contracts/wrapped-token-gateway
 */
interface IAaveWrappedTokenGateway {
    /// @notice deposit ETH to Aave, receive aWETH at the onBehalfOf address
    /// @dev msg.value is the ETH amount; pool is the Aave Pool contract address
    function depositETH(address pool, address onBehalfOf, uint16 referralCode) external payable;

    /// @notice withdraw ETH from Aave by burning aWETH
    /// @dev requires prior approval: aWETH.approve(gateway, amount)
    function withdrawETH(address pool, uint256 amount, address to) external;
}
