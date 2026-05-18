// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IMIM
 * @notice minimal interface for the MIM token, exposed to other contracts in the system
 */
interface IMIM {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function currentTier(address holder) external view returns (uint8);
    function currentMultiplier(address holder) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}
