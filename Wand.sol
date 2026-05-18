// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IWand} from "./interfaces/IWand.sol";
import {IMIM} from "./interfaces/IMIM.sol";

/// @dev minimal subset of Cauldron's view functions needed by Wand
/// @dev curvePoolKey() matches the ABI of the auto-generated getter for PoolKey public curvePoolKey
interface ICauldronView {
    function curvePoolKey() external view returns (
        Currency currency0,
        Currency currency1,
        uint24 fee,
        int24 tickSpacing,
        IHooks hooks
    );
    function quoteCast(uint256 ethIn) external view returns (uint256);
    function quoteDispel(uint256 mimIn) external view returns (uint256);
    function MIN_MINT_ETH() external view returns (uint256);
    function MAX_MINT_ETH() external view returns (uint256);
}

/**
 * @title Wand
 * @notice the frontend-facing router for casting and dispelling magic internet money
 * @dev thin convenience layer over Cauldron. Has no special privileges in the protocol —
 *      anyone could write their own router that does the same thing. Wand is just the
 *      canonical one we ship at mim.eth.
 *
 *      User flow:
 *      - cast(): user sends ETH with the call; Wand calls PoolManager.unlock() which
 *                triggers Cauldron's beforeSwap/afterSwap and mints MIM to the user.
 *      - dispel(): user calls dispel(amount); Wand triggers the same unlock pattern in
 *                  the burn direction. Cauldron burns MIM directly from the user's balance
 *                  (no approval to Wand required) and sends ETH directly to the user.
 *
 *      Both functions wrap the V4 PoolManager unlock callback pattern so the frontend
 *      doesn't have to. They also enforce slippage protection (minOut / minEthOut).
 */
contract Wand is IWand, IUnlockCallback, ReentrancyGuard {
    // ────────────────────────────────────────────────────────────────────────
    // CONSTANTS
    // ────────────────────────────────────────────────────────────────────────

    bytes32 internal constant ACTION_CAST = keccak256("CAST");
    bytes32 internal constant ACTION_DISPEL = keccak256("DISPEL");

    // ────────────────────────────────────────────────────────────────────────
    // IMMUTABLES
    // ────────────────────────────────────────────────────────────────────────

    IPoolManager public immutable POOL_MANAGER;
    address public immutable CAULDRON;
    IMIM public immutable MIM_TOKEN;

    // ────────────────────────────────────────────────────────────────────────
    // STORAGE — used only to pass data through the unlock callback
    // ────────────────────────────────────────────────────────────────────────

    /// @notice the active user during an in-flight unlock callback
    /// @dev transient — set by cast/dispel, read inside unlockCallback, cleared after
    address private _activeUser;

    /// @notice the ETH amount supplied for an in-flight cast
    /// @dev transient — set by cast, used inside unlockCallback
    uint256 private _activeEthAmount;

    /// @notice the MIM amount supplied for an in-flight dispel
    /// @dev transient — set by dispel, used inside unlockCallback
    uint256 private _activeMimAmount;

    /// @notice the action for the in-flight unlock callback
    /// @dev transient — ACTION_CAST or ACTION_DISPEL
    bytes32 private _activeAction;

    /// @notice user's MIM balance before cast — used to compute mint output
    uint256 private _userMimBalanceBefore;

    /// @notice user's ETH balance before dispel — used to compute ETH returned
    uint256 private _userEthBalanceBefore;

    // ────────────────────────────────────────────────────────────────────────
    // EVENTS
    // ────────────────────────────────────────────────────────────────────────

    event CastRouted(address indexed user, uint256 ethIn, uint256 mimOut);
    event DispelRouted(address indexed user, uint256 mimIn, uint256 ethOut);

    // ────────────────────────────────────────────────────────────────────────
    // ERRORS
    // ────────────────────────────────────────────────────────────────────────

    error InvalidAddress();
    error ZeroValue();
    error SlippageExceeded(uint256 expected, uint256 actual);
    error OnlyPoolManager();
    error UnauthorizedReentry();
    error UnknownAction();

    // ────────────────────────────────────────────────────────────────────────
    // CONSTRUCTOR
    // ────────────────────────────────────────────────────────────────────────

    constructor(IPoolManager _poolManager, address _cauldron, address _mimToken) {
        if (address(_poolManager) == address(0)) revert InvalidAddress();
        if (_cauldron == address(0)) revert InvalidAddress();
        if (_mimToken == address(0)) revert InvalidAddress();

        POOL_MANAGER = _poolManager;
        CAULDRON = _cauldron;
        MIM_TOKEN = IMIM(_mimToken);
    }

    // ────────────────────────────────────────────────────────────────────────
    // CAST — mint MIM by depositing ETH
    // ────────────────────────────────────────────────────────────────────────

    /**
     * @notice cast MIM by depositing ETH
     * @param minOut the minimum amount of MIM the caller will accept (slippage protection)
     * @return mimMinted the actual amount of MIM minted to the caller
     */
    function cast(uint256 minOut) external payable nonReentrant returns (uint256 mimMinted) {
        if (msg.value == 0) revert ZeroValue();
        if (_activeUser != address(0)) revert UnauthorizedReentry();

        // Snapshot user's MIM balance before the swap so we can compute mint amount after
        uint256 mimBefore = MIM_TOKEN.balanceOf(msg.sender);

        // Set transient state for the unlock callback
        _activeUser = msg.sender;
        _activeEthAmount = msg.value;
        _activeAction = ACTION_CAST;
        _userMimBalanceBefore = mimBefore;

        // Trigger the unlock callback — PoolManager will call unlockCallback(...)
        POOL_MANAGER.unlock(abi.encode(msg.sender, msg.value, ACTION_CAST));

        // Compute mint amount from balance delta
        uint256 mimAfter = MIM_TOKEN.balanceOf(msg.sender);
        mimMinted = mimAfter - mimBefore;

        // Clear transient state
        _activeUser = address(0);
        _activeEthAmount = 0;
        _activeAction = bytes32(0);
        _userMimBalanceBefore = 0;

        // Slippage check
        if (mimMinted < minOut) revert SlippageExceeded(minOut, mimMinted);

        emit CastRouted(msg.sender, msg.value, mimMinted);
    }

    // ────────────────────────────────────────────────────────────────────────
    // DISPEL — burn MIM for ETH
    // ────────────────────────────────────────────────────────────────────────

    /**
     * @notice dispel MIM by burning it for ETH
     * @dev Cauldron burns MIM directly from the caller's balance — no approval to Wand needed
     * @param mimAmount the amount of MIM to burn
     * @param minEthOut the minimum amount of ETH the caller will accept (slippage protection)
     * @return ethReturned the actual amount of ETH returned to the caller
     */
    function dispel(uint256 mimAmount, uint256 minEthOut) external nonReentrant returns (uint256 ethReturned) {
        if (mimAmount == 0) revert ZeroValue();
        if (_activeUser != address(0)) revert UnauthorizedReentry();

        // Snapshot user's ETH balance before swap
        uint256 ethBefore = msg.sender.balance;

        // Set transient state for unlock callback
        _activeUser = msg.sender;
        _activeMimAmount = mimAmount;
        _activeAction = ACTION_DISPEL;
        _userEthBalanceBefore = ethBefore;

        // Trigger unlock — PoolManager will call unlockCallback
        POOL_MANAGER.unlock(abi.encode(msg.sender, mimAmount, ACTION_DISPEL));

        // Compute returned ETH from balance delta
        uint256 ethAfter = msg.sender.balance;
        ethReturned = ethAfter - ethBefore;

        // Clear transient state
        _activeUser = address(0);
        _activeMimAmount = 0;
        _activeAction = bytes32(0);
        _userEthBalanceBefore = 0;

        if (ethReturned < minEthOut) revert SlippageExceeded(minEthOut, ethReturned);

        emit DispelRouted(msg.sender, mimAmount, ethReturned);
    }

    // ────────────────────────────────────────────────────────────────────────
    // UNLOCK CALLBACK — the V4 ritual
    // ────────────────────────────────────────────────────────────────────────

    /**
     * @notice called by PoolManager during cast/dispel to perform the actual swap
     * @dev only the PoolManager may call this. Reverts on direct calls.
     */
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert OnlyPoolManager();
        if (_activeUser == address(0)) revert UnauthorizedReentry();

        (address user, uint256 amount, bytes32 action) = abi.decode(data, (address, uint256, bytes32));

        // Get the curve pool key from Cauldron
        PoolKey memory key = _getCurvePoolKey();

        if (action == ACTION_CAST) {
            _executeCast(key, user, amount);
        } else if (action == ACTION_DISPEL) {
            _executeDispel(key, user, amount);
        } else {
            revert UnknownAction();
        }

        return "";
    }

    /// @dev internal cast execution within unlock callback
    function _executeCast(PoolKey memory key, address user, uint256 ethAmount) internal {
        // ETH is currency0 if its address sorts lower (address(0) always sorts below any token)
        bool zeroForOne = key.currency0.isAddressZero()
            || key.currency0 < Currency.wrap(address(MIM_TOKEN));

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(ethAmount), // negative = exact-input
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        bytes memory hookData = abi.encode(user, ACTION_CAST);

        // Settle ETH into PoolManager using the canonical V4 pattern:
        // sync() marks the current balance, then settle{value} pays and records the delta
        _settleETH(key, ethAmount);

        // Trigger the swap — Cauldron's beforeSwap/afterSwap handle the mint
        POOL_MANAGER.swap(key, params, hookData);

        // Settlement: ETH was settled in; MIM was minted by Cauldron directly to user.
        // No further accounting needed here.
    }

    /// @dev internal dispel execution within unlock callback
    function _executeDispel(PoolKey memory key, address user, uint256 mimAmount) internal {
        // Dispel is the reverse direction of cast
        bool zeroForOne = !(key.currency0.isAddressZero()
            || key.currency0 < Currency.wrap(address(MIM_TOKEN)));

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(mimAmount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        bytes memory hookData = abi.encode(user, ACTION_DISPEL);

        // Trigger the swap — Cauldron's _settleDispel burns MIM directly from user
        // and sends ETH directly back to user. No MIM needs to pass through Wand.
        POOL_MANAGER.swap(key, params, hookData);
    }

    /// @dev settle native ETH with PoolManager using the canonical V4 pattern
    /// @dev mirrors DeltaResolver._settle: sync() then settle{value: amount}()
    function _settleETH(PoolKey memory key, uint256 amount) internal {
        Currency ethCurrency = key.currency0.isAddressZero() ? key.currency0 : key.currency1;
        POOL_MANAGER.sync(ethCurrency);
        POOL_MANAGER.settle{value: amount}();
    }

    // ────────────────────────────────────────────────────────────────────────
    // QUOTES — passthrough to Cauldron's view functions
    // ────────────────────────────────────────────────────────────────────────

    function quoteCast(uint256 ethIn) external view returns (uint256) {
        return ICauldronView(CAULDRON).quoteCast(ethIn);
    }

    function quoteDispel(uint256 mimIn) external view returns (uint256) {
        return ICauldronView(CAULDRON).quoteDispel(mimIn);
    }

    /// @notice the minimum ETH amount accepted for a single cast
    function minCastETH() external view returns (uint256) {
        return ICauldronView(CAULDRON).MIN_MINT_ETH();
    }

    /// @notice the maximum ETH amount accepted for a single cast
    function maxCastETH() external view returns (uint256) {
        return ICauldronView(CAULDRON).MAX_MINT_ETH();
    }

    // ────────────────────────────────────────────────────────────────────────
    // SAFETY FALLBACKS
    // ────────────────────────────────────────────────────────────────────────

    /// @notice accept ETH refunds from PoolManager during swap settlement
    receive() external payable {
        // PoolManager can send refunds during settle(); accept silently
    }

    /// @notice reconstruct the curve PoolKey from Cauldron's public storage getter
    /// @dev The auto-getter for `PoolKey public curvePoolKey` returns individual fields
    function _getCurvePoolKey() internal view returns (PoolKey memory) {
        (
            Currency currency0,
            Currency currency1,
            uint24 fee,
            int24 tickSpacing,
            IHooks hooks
        ) = ICauldronView(CAULDRON).curvePoolKey();

        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });
    }
}
