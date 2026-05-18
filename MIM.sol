// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IGrimoire} from "./interfaces/IGrimoire.sol";

/**
 * @title MIM
 * @notice magic internet money — custom erc-20 with hold-time tracking for the gravity bonding curve
 * @dev
 *   - mintable/burnable only by Cauldron (set immutably at construction)
 *   - transfer hooks track per-wallet tier-start block
 *   - any decrease in balance (sending out tokens) resets the sender's tier-start
 *   - first non-zero balance for a wallet initializes its tier-start clock
 *   - tier is computed on-the-fly as a view function (not stored)
 *   - emits TierUpdated and MultiplierReset events for indexer/frontend
 *
 * Tier table (matches whitepaper § holding):
 *   mortal:    0–7 days     · multiplier 1.0× (10000 bps)
 *   summoner:  7–30 days    · multiplier 1.5× (15000 bps)
 *   conjurer:  30–90 days   · multiplier 2.5× (25000 bps)
 *   wizard:    90+ days     · multiplier 4.0× (40000 bps)
 *
 * Block-time assumption: 2 seconds per block on Base.
 *   7 days  = 302,400 blocks
 *   30 days = 1,296,000 blocks
 *   90 days = 3,888,000 blocks
 */
contract MIM is ERC20 {
    // ────────────────────────────────────────────────────────────────────────
    // CONSTANTS
    // ────────────────────────────────────────────────────────────────────────

    /// @notice block intervals for tier boundaries on Base (2-second blocks)
    uint64 public constant BLOCKS_PER_DAY = 43_200;     // 86400s / 2s per block
    uint64 public constant TIER_SUMMONER_BLOCK_THRESHOLD = 7 * BLOCKS_PER_DAY;   //  302,400
    uint64 public constant TIER_CONJURER_BLOCK_THRESHOLD = 30 * BLOCKS_PER_DAY;  // 1,296,000
    uint64 public constant TIER_WIZARD_BLOCK_THRESHOLD = 90 * BLOCKS_PER_DAY;    // 3,888,000

    /// @notice multiplier values in basis points (10000 = 1.0×)
    uint256 public constant MULTIPLIER_MORTAL = 10_000;    // 1.0×
    uint256 public constant MULTIPLIER_SUMMONER = 15_000;  // 1.5×
    uint256 public constant MULTIPLIER_CONJURER = 25_000;  // 2.5×
    uint256 public constant MULTIPLIER_WIZARD = 40_000;    // 4.0×

    /// @notice tier identifiers
    uint8 public constant TIER_MORTAL = 0;
    uint8 public constant TIER_SUMMONER = 1;
    uint8 public constant TIER_CONJURER = 2;
    uint8 public constant TIER_WIZARD = 3;

    // ────────────────────────────────────────────────────────────────────────
    // IMMUTABLES
    // ────────────────────────────────────────────────────────────────────────

    /// @notice the only address that can mint/burn — set once at construction
    address public immutable CAULDRON;

    /// @notice the grimoire registry — receives tier-update events
    address public immutable GRIMOIRE;

    // ────────────────────────────────────────────────────────────────────────
    // STORAGE
    // ────────────────────────────────────────────────────────────────────────

    /// @notice block number when each wallet's current tier window started
    /// @dev resets to current block on any outbound transfer; initialized on first balance
    mapping(address => uint64) public tierStartBlock;

    /// @notice block when wallet first held a non-zero balance (lifetime marker)
    /// @dev never resets, even if balance goes to 0 and back
    mapping(address => uint64) public firstBalanceBlock;

    // ────────────────────────────────────────────────────────────────────────
    // EVENTS
    // ────────────────────────────────────────────────────────────────────────

    event TierUpdated(address indexed holder, uint8 oldTier, uint8 newTier, uint64 atBlock);
    event MultiplierReset(address indexed holder, uint64 atBlock, uint256 amountTransferred);

    // ────────────────────────────────────────────────────────────────────────
    // ERRORS
    // ────────────────────────────────────────────────────────────────────────

    error OnlyCauldron();
    error InvalidAddress();

    // ────────────────────────────────────────────────────────────────────────
    // MODIFIERS
    // ────────────────────────────────────────────────────────────────────────

    modifier onlyCauldron() {
        if (msg.sender != CAULDRON) revert OnlyCauldron();
        _;
    }

    // ────────────────────────────────────────────────────────────────────────
    // CONSTRUCTOR
    // ────────────────────────────────────────────────────────────────────────

    /// @param _cauldron the v4 hook contract that controls minting/burning
    /// @param _grimoire the identity registry for tier-update notifications
    constructor(address _cauldron, address _grimoire) ERC20("magic internet money", "mim") {
        if (_cauldron == address(0)) revert InvalidAddress();
        if (_grimoire == address(0)) revert InvalidAddress();
        CAULDRON = _cauldron;
        GRIMOIRE = _grimoire;
    }

    // ────────────────────────────────────────────────────────────────────────
    // MINT / BURN (restricted to Cauldron)
    // ────────────────────────────────────────────────────────────────────────

    /// @notice mint mim to a recipient — only callable by Cauldron
    /// @dev transfer hooks will fire to update tier state for the recipient
    function mint(address to, uint256 amount) external onlyCauldron {
        _mint(to, amount);
    }

    /// @notice burn mim from a wallet — only callable by Cauldron
    /// @dev transfer hooks will fire to update tier state for the burner
    function burn(address from, uint256 amount) external onlyCauldron {
        _burn(from, amount);
    }

    // ────────────────────────────────────────────────────────────────────────
    // TRANSFER HOOK (OpenZeppelin v5 _update pattern)
    // ────────────────────────────────────────────────────────────────────────

    /**
     * @notice override _update to implement tier-tracking on every balance change
     * @dev
     *   This function is called by ERC-20 transfer, mint, and burn.
     *   - from == address(0): mint to `to`
     *   - to == address(0): burn from `from`
     *   - otherwise: standard transfer
     *
     *   Rules:
     *   - On any outbound balance decrease for `from` (transfer or burn):
     *       reset from's tierStartBlock to current block
     *   - On any inbound balance increase for `to` (transfer or mint):
     *       if to's firstBalanceBlock is 0, initialize it AND set tierStartBlock
     *
     *   Edge cases handled:
     *   - self-transfers (from == to): treated as outbound for `from`, no-op for `to`
     *   - zero-amount transfers: skipped (standard ERC-20 allows them; we do too but no tier effect)
     *   - mint to existing holder: tierStartBlock NOT reset (only outbound resets)
     */
    function _update(address from, address to, uint256 amount) internal override {
        // Cache current tiers BEFORE the balance change for accurate event emission
        uint8 fromTierBefore = (from == address(0)) ? 0 : currentTier(from);
        uint8 toTierBefore = (to == address(0)) ? 0 : currentTier(to);

        // Execute the standard ERC-20 balance update (this is where the actual transfer happens)
        super._update(from, to, amount);

        // Skip tier logic for zero-amount transfers (no economic effect)
        if (amount == 0) return;

        uint64 currentBlock = uint64(block.number);

        // ─── Sender side: any outbound transfer resets multiplier ───
        // Skip when from == address(0) (mint, no sender)
        // Skip when from == to (self-transfer would penalize ourselves for nothing)
        if (from != address(0) && from != to) {
            _resetTier(from, currentBlock, amount, fromTierBefore);
        }

        // ─── Recipient side: initialize tier on first non-zero balance ───
        // Skip when to == address(0) (burn, no recipient)
        if (to != address(0) && to != from) {
            _initializeTierIfNeeded(to, currentBlock, toTierBefore);
        }
    }

    /// @dev internal helper: reset sender's tier window
    function _resetTier(address holder, uint64 currentBlock, uint256 amount, uint8 oldTier) internal {
        tierStartBlock[holder] = currentBlock;

        emit MultiplierReset(holder, currentBlock, amount);

        // Emit tier update if their tier actually changed (it will, going to mortal)
        if (oldTier != TIER_MORTAL) {
            emit TierUpdated(holder, oldTier, TIER_MORTAL, currentBlock);

            // Notify Grimoire so it can record the tier change
            // We use a try/catch pattern via low-level call to ensure a Grimoire
            // failure doesn't brick MIM transfers
            _notifyGrimoireOfTierChange(holder, TIER_MORTAL, currentBlock);
        }
    }

    /// @dev internal helper: initialize tier for new holders
    function _initializeTierIfNeeded(address holder, uint64 currentBlock, uint8 oldTier) internal {
        // If this is the wallet's first time holding a non-zero balance, set the clock
        if (firstBalanceBlock[holder] == 0) {
            firstBalanceBlock[holder] = currentBlock;
            tierStartBlock[holder] = currentBlock;
            // Tier is already MORTAL by virtue of fresh tierStartBlock; no event needed
        }
        // If they already have a tierStartBlock, leave it alone — receiving tokens doesn't reset

        // Note: oldTier is unused here because receiving tokens never changes tier.
        // We keep the parameter for symmetry and potential future use (e.g. logging).
        oldTier;
    }

    /// @dev notify Grimoire via low-level call; failures do not revert the transfer
    function _notifyGrimoireOfTierChange(address holder, uint8 newTier, uint64 atBlock) internal {
        bytes memory data = abi.encodeWithSignature(
            "recordTierChange(address,uint8,uint64)",
            holder,
            newTier,
            atBlock
        );
        // Intentionally use a low-level call with capped gas to ensure the call cannot
        // brick token transfers even if Grimoire is broken. The indexer can also pick up
        // the TierUpdated event as a fallback.
        (bool success, ) = GRIMOIRE.call{gas: 100_000}(data);
        // We don't revert on failure — events are the canonical source for the indexer
        success;
    }

    // ────────────────────────────────────────────────────────────────────────
    // VIEW FUNCTIONS
    // ────────────────────────────────────────────────────────────────────────

    /// @notice compute the current tier for a holder
    /// @dev pure function of (currentBlock - tierStartBlock); no storage write
    function currentTier(address holder) public view returns (uint8) {
        uint64 startBlock = tierStartBlock[holder];

        // Edge case: holder has never had a balance
        if (startBlock == 0) return TIER_MORTAL;

        uint64 currentBlock = uint64(block.number);

        // Defensive: if somehow tierStartBlock is in the future, treat as mortal
        // (shouldn't happen in normal flow but protects against weird edge cases)
        if (currentBlock <= startBlock) return TIER_MORTAL;

        uint64 blocksHeld = currentBlock - startBlock;

        if (blocksHeld >= TIER_WIZARD_BLOCK_THRESHOLD) return TIER_WIZARD;
        if (blocksHeld >= TIER_CONJURER_BLOCK_THRESHOLD) return TIER_CONJURER;
        if (blocksHeld >= TIER_SUMMONER_BLOCK_THRESHOLD) return TIER_SUMMONER;
        return TIER_MORTAL;
    }

    /// @notice compute current multiplier (in basis points) for a holder
    /// @dev 10000 = 1.0×, 15000 = 1.5×, etc.
    function currentMultiplier(address holder) public view returns (uint256) {
        uint8 tier = currentTier(holder);
        if (tier == TIER_WIZARD) return MULTIPLIER_WIZARD;
        if (tier == TIER_CONJURER) return MULTIPLIER_CONJURER;
        if (tier == TIER_SUMMONER) return MULTIPLIER_SUMMONER;
        return MULTIPLIER_MORTAL;
    }

    /// @notice how many blocks until the next tier upgrade for a holder
    /// @return blocksRemaining 0 if already at wizard tier or has never held
    /// @return nextTier the tier they would ascend to (TIER_WIZARD if maxed)
    function blocksUntilNextTier(address holder) public view returns (uint256 blocksRemaining, uint8 nextTier) {
        uint64 startBlock = tierStartBlock[holder];
        if (startBlock == 0) return (0, TIER_MORTAL);

        uint64 currentBlock = uint64(block.number);
        if (currentBlock <= startBlock) return (TIER_SUMMONER_BLOCK_THRESHOLD, TIER_SUMMONER);

        uint64 blocksHeld = currentBlock - startBlock;

        if (blocksHeld < TIER_SUMMONER_BLOCK_THRESHOLD) {
            return (TIER_SUMMONER_BLOCK_THRESHOLD - blocksHeld, TIER_SUMMONER);
        }
        if (blocksHeld < TIER_CONJURER_BLOCK_THRESHOLD) {
            return (TIER_CONJURER_BLOCK_THRESHOLD - blocksHeld, TIER_CONJURER);
        }
        if (blocksHeld < TIER_WIZARD_BLOCK_THRESHOLD) {
            return (TIER_WIZARD_BLOCK_THRESHOLD - blocksHeld, TIER_WIZARD);
        }
        return (0, TIER_WIZARD);
    }
}
