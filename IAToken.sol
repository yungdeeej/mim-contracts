// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IAToken
 * @notice Aave's interest-bearing receipt token (e.g. aWETH)
 * @dev balanceOf returns the underlying amount including accrued interest
 *      so checking aWETH.balanceOf(cauldron) tells us our current ETH-redeemable position
 */
interface IAToken is IERC20 {
    function POOL() external view returns (address);
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}
