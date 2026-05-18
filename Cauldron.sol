// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ─── External imports ───
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ─── Internal imports ───
import {IMIM} from "./interfaces/IMIM.sol";
import {IGrimoire} from "./interfaces/IGrimoire.sol";
import {IWellspring} from "./interfaces/IWellspring.sol";
import {IAaveV3Pool} from "./interfaces/IAaveV3Pool.sol";
import {IAaveWrappedTokenGateway} from "./interfaces/IAaveWrappedTokenGateway.sol";
import {IAToken} from "./interfaces/IAToken.sol";
import {CauldronMath} from "./libraries/CauldronMath.sol";

/**
 * @title Cauldron
 * @notice the v4 hook implementing the gravity bonding curve for magic internet money
 * @dev the heart of $MIM. immutable, no admin, no upgrade path. holds the reserve.
 *      only writer to MIM (mint/burn). primary writer to Grimoire. depositor to Wellspring.
 *
 *   Architecture per SPEC §2, §3, §6, §7, §14:
 *   - Forward curve: q(e, t) = K(t) * (1 - e^(-e/S)), S = 500 ETH
 *   - Gravity: K(t) = K_INITIAL - 0.5 * M(t), where M(t) is lifetime mints
 *   - Anti-MEV: 5 ETH cap, same-block-burn revert, 100-block random multiplier
 *   - Reserve: 85% raw ETH, 15% Aave aWETH
 *   - Fee: 0.3% on both sides, permanently locked in reserve
 *   - Fold: at convergence, supply equals cap, minting halts forever
 *
 *   Pattern note: this Cauldron deliberately uses a simplified hook-data routing scheme
 *   rather than the full V4 unlock callback pattern. Users call into Wand (the router),
 *   which calls PoolManager.swap with hookData encoding (user, action). beforeSwap reads
 *   the hookData to determine cast vs dispel and returns a BeforeSwapDelta that overrides
 *   the standard AMM. afterSwap then mints/burns MIM and updates state.
 */
contract Cauldron is IHooks, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using Hooks for IHooks;

    // ────────────────────────────────────────────────────────────────────────
    // CONSTANTS (per SPEC §14)
    // ────────────────────────────────────────────────────────────────────────

    uint256 public constant K_INITIAL = 21_000_000e18;
    uint256 public constant S = 500e18;
    uint256 public constant GAMMA = 0.5e18;
    uint256 public constant MAX_MINT_ETH = 5e18;
    uint256 public constant MIN_MINT_ETH = 0.001e18;
    uint256 public constant PROTOCOL_FEE_BPS = 30;
    uint256 public constant PRODUCTIVE_TARGET_BPS = 1500;
    uint256 public constant MULTIPLIER_WINDOW = 100;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant HARVEST_BOUNTY_BPS = 50;
    uint256 public constant SEAL_BATCH_SIZE_MAX = 200;

    // hookData action identifiers
    bytes32 internal constant ACTION_CAST = keccak256("CAST");
    bytes32 internal constant ACTION_DISPEL = keccak256("DISPEL");

    // ────────────────────────────────────────────────────────────────────────
    // IMMUTABLES
    // ────────────────────────────────────────────────────────────────────────

    IPoolManager public immutable POOL_MANAGER;
    IMIM public immutable MIM_TOKEN;
    IGrimoire public immutable GRIMOIRE;
    IWellspring public immutable WELLSPRING;
    IAaveV3Pool public immutable AAVE_POOL;
    IAaveWrappedTokenGateway public immutable AAVE_GATEWAY;
    IAToken public immutable AWETH;
    uint256 public immutable DEPLOYMENT_BLOCK;
    bytes32 public immutable MANIFESTO_HASH;

    // ────────────────────────────────────────────────────────────────────────
    // STATE
    // ────────────────────────────────────────────────────────────────────────

    PoolKey public curvePoolKey;
    bool public curvePoolInitialized;

    /// @notice cumulative MIM ever minted; M(t) in curve math; never decreases
    uint256 public lifetimeMinted;

    /// @notice cumulative ETH ever deposited via mints (gross of fees); never decreases
    uint256 public ethCumulative;

    /// @notice raw ETH balance held by this contract for the 85% floor
    uint256 public ethFloorBalance;

    /// @notice cumulative protocol fees accumulated (part of ethFloorBalance; never withdrawable)
    uint256 public totalProtocolFees;

    /// @notice block at which each address last minted (anti same-block-burn)
    mapping(address => uint256) public lastMintBlock;

    /// @notice has the fold (convergence) been reached
    bool public foldReached;

    /// @notice block at which fold was reached
    uint256 public foldBlock;

    /// @notice total ETH harvested and forwarded to Wellspring across all harvests
    uint256 public totalHarvested;

    /// @notice baseline aWETH balance against which yield is measured at each harvest
    /// @dev increased on every supply, decreased on every withdrawal at cost basis
    uint256 public productiveLayerCostBasis;

    // ────────────────────────────────────────────────────────────────────────
    // EVENTS
    // ────────────────────────────────────────────────────────────────────────

    event Cast(
        address indexed user,
        uint256 ethIn,
        uint256 mimOut,
        uint256 newCap,
        uint256 capReduction
    );
    event Dispel(address indexed user, uint256 mimIn, uint256 ethOut);
    event Harvest(address indexed caller, uint256 yieldAmount, uint256 bounty);
    event FoldReached(uint256 atBlock, uint256 finalSupply, uint256 reserveETH);
    event ReserveContribution(address indexed from, uint256 amount);
    event ReserveRebalanced(uint256 floorBalance, uint256 productiveBalance);
    event PoolInitialized(PoolId indexed poolId);
    event WizardsSealed(uint256 count, uint64 atBlock);

    // ────────────────────────────────────────────────────────────────────────
    // ERRORS
    // ────────────────────────────────────────────────────────────────────────

    error InvalidAddress();
    error MintExceedsMaxPerTx();
    error MintBelowMinimum();
    error SameBlockBurnRestricted();
    error CapAlreadyConverged();
    error PoolAlreadyInitialized();
    error UnauthorizedPool();
    error LiquidityModificationBlocked();
    error InvalidHookData();
    error TransferFailed();
    error InsufficientReserve();
    error InsufficientSupply();
    error FoldNotReached();
    error FoldAlreadyReached();
    error BatchTooLarge();
    error AaveWithdrawalShortfall();
    error NotPoolManager();

    // ────────────────────────────────────────────────────────────────────────
    // MODIFIERS
    // ────────────────────────────────────────────────────────────────────────

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        _;
    }

    // ────────────────────────────────────────────────────────────────────────
    // CONSTRUCTOR
    // ────────────────────────────────────────────────────────────────────────

    constructor(
        IPoolManager _poolManager,
        address _mimToken,
        address _grimoire,
        address _wellspring,
        address _aavePool,
        address _aaveGateway,
        address _aWETH,
        bytes32 _manifestoHash
    ) {
        if (address(_poolManager) == address(0)) revert InvalidAddress();
        if (_mimToken == address(0)) revert InvalidAddress();
        if (_grimoire == address(0)) revert InvalidAddress();
        if (_wellspring == address(0)) revert InvalidAddress();
        if (_aavePool == address(0)) revert InvalidAddress();
        if (_aaveGateway == address(0)) revert InvalidAddress();
        if (_aWETH == address(0)) revert InvalidAddress();

        POOL_MANAGER = _poolManager;
        MIM_TOKEN = IMIM(_mimToken);
        GRIMOIRE = IGrimoire(_grimoire);
        WELLSPRING = IWellspring(_wellspring);
        AAVE_POOL = IAaveV3Pool(_aavePool);
        AAVE_GATEWAY = IAaveWrappedTokenGateway(_aaveGateway);
        AWETH = IAToken(_aWETH);

        DEPLOYMENT_BLOCK = block.number;
        MANIFESTO_HASH = _manifestoHash;
    }

    // ────────────────────────────────────────────────────────────────────────
    // HOOK PERMISSIONS — utility for CREATE2 address validation
    // ────────────────────────────────────────────────────────────────────────

    /// @notice returns the hook permissions bitmap; used off-chain for salt mining
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ────────────────────────────────────────────────────────────────────────
    // IHooks IMPLEMENTATION
    // ────────────────────────────────────────────────────────────────────────

    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) external override onlyPoolManager returns (bytes4) {
        if (curvePoolInitialized) revert PoolAlreadyInitialized();
        curvePoolKey = key;
        curvePoolInitialized = true;
        emit PoolInitialized(key.toId());
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external pure override returns (bytes4)
    {
        revert LiquidityModificationBlocked();
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert LiquidityModificationBlocked();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert LiquidityModificationBlocked();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert LiquidityModificationBlocked();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert LiquidityModificationBlocked();
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(curvePoolKey.toId())) {
            revert UnauthorizedPool();
        }

        if (hookData.length < 64) revert InvalidHookData();
        (address user, bytes32 action) = abi.decode(hookData, (address, bytes32));

        if (action == ACTION_CAST) {
            return _validateCast(user, params);
        } else if (action == ACTION_DISPEL) {
            return _validateDispel(user, params);
        } else {
            revert InvalidHookData();
        }
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(curvePoolKey.toId())) {
            revert UnauthorizedPool();
        }

        (address user, bytes32 action) = abi.decode(hookData, (address, bytes32));

        if (action == ACTION_CAST) {
            _settleCast(user, params);
        } else if (action == ACTION_DISPEL) {
            _settleDispel(user, params);
        }

        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4)
    {
        revert LiquidityModificationBlocked();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4)
    {
        revert LiquidityModificationBlocked();
    }

    // ────────────────────────────────────────────────────────────────────────
    // CAST VALIDATION & SETTLEMENT
    // ────────────────────────────────────────────────────────────────────────

    function _validateCast(
        address,
        SwapParams calldata params
    ) internal view returns (bytes4, BeforeSwapDelta, uint24) {
        if (foldReached) revert CapAlreadyConverged();

        uint256 cap = CauldronMath.currentCap(lifetimeMinted);
        if (cap == 0 || cap <= circulatingSupply()) revert CapAlreadyConverged();

        uint256 ethIn = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        if (ethIn < MIN_MINT_ETH) revert MintBelowMinimum();
        if (ethIn > MAX_MINT_ETH) revert MintExceedsMaxPerTx();

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _validateDispel(
        address user,
        SwapParams calldata
    ) internal view returns (bytes4, BeforeSwapDelta, uint24) {
        if (lastMintBlock[user] == block.number) revert SameBlockBurnRestricted();
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev settles a cast: mints MIM, splits ETH 85/15, updates state, writes Grimoire
    function _settleCast(address user, SwapParams calldata params) internal {
        uint256 ethIn = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        // Take protocol fee off the top (stays in reserve as ethFloorBalance)
        uint256 fee = (ethIn * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 ethForCurve = ethIn - fee;

        // Compute mint amount using current cap (before this mint's gravity reduction)
        uint256 cap = CauldronMath.currentCap(lifetimeMinted);
        uint256 mintAmt = CauldronMath.mintAmount(ethCumulative, ethForCurve, cap);

        // Apply random multiplier if in anti-MEV window
        if (block.number < DEPLOYMENT_BLOCK + MULTIPLIER_WINDOW) {
            uint256 multBps = CauldronMath.randomMultiplierBps(
                block.timestamp,
                block.prevrandao,
                user,
                ethIn
            );
            mintAmt = (mintAmt * multBps) / BPS_DENOMINATOR;
        }

        if (mintAmt == 0) revert CapAlreadyConverged();

        // Update state BEFORE external calls (CEI pattern)
        ethCumulative += ethForCurve;
        lifetimeMinted += mintAmt;
        totalProtocolFees += fee;
        lastMintBlock[user] = block.number;

        // Compute cap reduction for Grimoire reporting (gamma * mintAmount)
        uint256 capReduction = (GAMMA * mintAmt) / 1e18;
        uint256 newCap = CauldronMath.currentCap(lifetimeMinted);

        // Mint the MIM
        MIM_TOKEN.mint(user, mintAmt);

        // Split ETH: 85% stays as raw floor, 15% goes to Aave (target).
        // We keep all ETH as floor initially and rebalance afterward to avoid
        // making the cast tx fail if Aave is paused/full.
        ethFloorBalance += ethIn;

        // Try to rebalance into Aave; on failure, ETH stays in floor (still safe)
        _rebalanceTowardTarget();

        // Check for fold convergence
        uint256 supply = MIM_TOKEN.totalSupply();
        if (!foldReached && supply >= newCap && newCap > 0) {
            foldReached = true;
            foldBlock = block.number;
            emit FoldReached(block.number, supply, ethFloorBalance + _productiveLayerValue());
        }

        // Write to Grimoire (after all our state is consistent)
        GRIMOIRE.recordCast(user, mintAmt, capReduction, MIM_TOKEN.balanceOf(user));

        emit Cast(user, ethIn, mintAmt, newCap, capReduction);
    }

    /// @dev settles a dispel: burns MIM, returns ETH (unstaking from Aave if needed)
    function _settleDispel(address user, SwapParams calldata params) internal {
        uint256 mimIn = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        if (MIM_TOKEN.balanceOf(user) < mimIn) revert InsufficientSupply();

        // Compute ETH out via inverse curve
        uint256 supply = MIM_TOKEN.totalSupply();
        uint256 cap = CauldronMath.currentCap(lifetimeMinted);

        // Edge case: if fold has been reached, use a cap that allows burns
        // (inverse curve requires cap > supply, but post-fold supply == cap)
        uint256 effectiveCap = (supply >= cap) ? supply + 1 : cap;
        uint256 ethOutGross = CauldronMath.burnReturn(supply, mimIn, effectiveCap);

        // Protocol fee on burn side (stays in reserve)
        uint256 fee = (ethOutGross * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 ethOut = ethOutGross - fee;

        // Make sure we have ETH to pay; unstake from Aave if necessary
        if (ethFloorBalance < ethOut) {
            uint256 shortfall = ethOut - ethFloorBalance;
            _withdrawFromAave(shortfall);
            if (ethFloorBalance < ethOut) revert InsufficientReserve();
        }

        // Update state
        ethFloorBalance -= ethOut;
        totalProtocolFees += fee;

        // Burn MIM
        MIM_TOKEN.burn(user, mimIn);

        // Send ETH
        (bool success, ) = user.call{value: ethOut}("");
        if (!success) revert TransferFailed();

        // Write to Grimoire
        GRIMOIRE.recordDispel(user, mimIn, MIM_TOKEN.balanceOf(user));

        // Rebalance reserve toward target (Aave deposit if floor now > 85%)
        _rebalanceTowardTarget();

        emit Dispel(user, mimIn, ethOut);
    }

    // ────────────────────────────────────────────────────────────────────────
    // RESERVE REBALANCING (85/15 ETH/aWETH split)
    // ────────────────────────────────────────────────────────────────────────

    function _rebalanceTowardTarget() internal {
        uint256 totalReserve = ethFloorBalance + _productiveLayerValue();
        if (totalReserve == 0) return;

        uint256 productiveTarget = (totalReserve * PRODUCTIVE_TARGET_BPS) / BPS_DENOMINATOR;
        uint256 productiveCurrent = _productiveLayerValue();

        if (productiveCurrent < productiveTarget) {
            uint256 toDeposit = productiveTarget - productiveCurrent;
            if (toDeposit > ethFloorBalance) toDeposit = ethFloorBalance;
            if (toDeposit > 0) {
                _depositToAave(toDeposit);
            }
        }
    }

    function _depositToAave(uint256 amount) internal {
        if (amount == 0) return;
        if (amount > ethFloorBalance) return;

        ethFloorBalance -= amount;
        productiveLayerCostBasis += amount;

        try AAVE_GATEWAY.depositETH{value: amount}(address(AAVE_POOL), address(this), 0) {
            emit ReserveRebalanced(ethFloorBalance, _productiveLayerValue());
        } catch {
            ethFloorBalance += amount;
            productiveLayerCostBasis -= amount;
        }
    }

    function _withdrawFromAave(uint256 amount) internal {
        if (amount == 0) return;

        uint256 aWETHBalance = AWETH.balanceOf(address(this));
        if (aWETHBalance == 0) revert AaveWithdrawalShortfall();

        uint256 toWithdraw = amount > aWETHBalance ? aWETHBalance : amount;
        IERC20(address(AWETH)).approve(address(AAVE_GATEWAY), toWithdraw);

        uint256 ethBefore = address(this).balance;
        AAVE_GATEWAY.withdrawETH(address(AAVE_POOL), toWithdraw, address(this));
        uint256 received = address(this).balance - ethBefore;

        if (received == 0) revert AaveWithdrawalShortfall();

        ethFloorBalance += received;

        if (toWithdraw <= productiveLayerCostBasis) {
            productiveLayerCostBasis -= toWithdraw;
        } else {
            productiveLayerCostBasis = 0;
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // HARVEST — extract Aave yield and forward to Wellspring
    // ────────────────────────────────────────────────────────────────────────

    function harvest() external nonReentrant {
        uint256 currentValue = _productiveLayerValue();
        if (currentValue <= productiveLayerCostBasis) return;

        uint256 yieldAmount = currentValue - productiveLayerCostBasis;

        uint256 ethBefore = address(this).balance;

        IERC20(address(AWETH)).approve(address(AAVE_GATEWAY), yieldAmount);
        try AAVE_GATEWAY.withdrawETH(address(AAVE_POOL), yieldAmount, address(this)) {
            // ok
        } catch {
            return;
        }

        uint256 received = address(this).balance - ethBefore;
        if (received == 0) return;

        uint256 bounty = (received * HARVEST_BOUNTY_BPS) / BPS_DENOMINATOR;
        uint256 toWellspring = received - bounty;

        totalHarvested += received;

        if (bounty > 0) {
            (bool successB, ) = msg.sender.call{value: bounty}("");
            if (!successB) revert TransferFailed();
        }

        if (toWellspring > 0) {
            (bool successW, ) = address(WELLSPRING).call{value: toWellspring}("");
            if (!successW) revert TransferFailed();
        }

        emit Harvest(msg.sender, received, bounty);
    }

    // ────────────────────────────────────────────────────────────────────────
    // FOLD — seal wizards who held through convergence
    // ────────────────────────────────────────────────────────────────────────

    function sealWizardsInFold(address[] calldata wallets) external {
        if (!foldReached) revert FoldNotReached();
        if (wallets.length > SEAL_BATCH_SIZE_MAX) revert BatchTooLarge();
        if (wallets.length == 0) return;

        GRIMOIRE.sealWizardsInFold(wallets, uint64(foldBlock));
        emit WizardsSealed(wallets.length, uint64(foldBlock));
    }

    // ────────────────────────────────────────────────────────────────────────
    // RESERVE CONTRIBUTION (from Grimoire name fees, etc.)
    // ────────────────────────────────────────────────────────────────────────

    receive() external payable {
        if (msg.value > 0) {
            ethFloorBalance += msg.value;
            emit ReserveContribution(msg.sender, msg.value);
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // VIEW HELPERS
    // ────────────────────────────────────────────────────────────────────────

    function currentCap() public view returns (uint256) {
        return CauldronMath.currentCap(lifetimeMinted);
    }

    function circulatingSupply() public view returns (uint256) {
        return MIM_TOKEN.totalSupply();
    }

    function productiveLayerValue() public view returns (uint256) {
        return _productiveLayerValue();
    }

    function _productiveLayerValue() internal view returns (uint256) {
        return AWETH.balanceOf(address(this));
    }

    function totalReserveValue() external view returns (uint256) {
        return ethFloorBalance + _productiveLayerValue();
    }

    function marginalMintPrice() external view returns (uint256) {
        return CauldronMath.marginalPrice(ethCumulative, currentCap());
    }

    function quoteCast(uint256 ethIn) external view returns (uint256) {
        if (foldReached) return 0;
        if (ethIn < MIN_MINT_ETH || ethIn > MAX_MINT_ETH) return 0;

        uint256 cap = currentCap();
        if (cap == 0) return 0;

        uint256 ethForCurve = ethIn - (ethIn * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        return CauldronMath.mintAmount(ethCumulative, ethForCurve, cap);
    }

    function quoteDispel(uint256 mimIn) external view returns (uint256) {
        uint256 supply = MIM_TOKEN.totalSupply();
        if (mimIn == 0 || mimIn > supply) return 0;

        uint256 cap = currentCap();
        uint256 effectiveCap = (supply >= cap) ? supply + 1 : cap;

        uint256 gross = CauldronMath.burnReturn(supply, mimIn, effectiveCap);
        uint256 fee = (gross * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        return gross - fee;
    }

    function pendingYield() external view returns (uint256) {
        uint256 value = _productiveLayerValue();
        if (value <= productiveLayerCostBasis) return 0;
        return value - productiveLayerCostBasis;
    }

    function blocksUntilFullDeterminism() external view returns (uint256) {
        uint256 end = DEPLOYMENT_BLOCK + MULTIPLIER_WINDOW;
        if (block.number >= end) return 0;
        return end - block.number;
    }
}
