// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IGrimoire} from "./interfaces/IGrimoire.sol";
import {IMIM} from "./interfaces/IMIM.sol";

/**
 * @title Grimoire
 * @notice immutable per-wallet history registry for magic internet money
 * @dev
 *   - written by exactly three authorized contracts: Cauldron, Wellspring, MIM
 *   - addresses are set at construction and locked forever
 *   - history is append-only: lifetime counters only ever increase
 *   - wizard numbers are assigned sequentially on first cast, never reused
 *   - name binding is permissionless but costs REBIND_FEE which routes to Cauldron's reserve
 *
 *   The "no operator" guarantee:
 *   - no admin functions
 *   - no upgrade path
 *   - no way to delete, modify, or hide any wallet's history
 *   - reserve fee forwarding to Cauldron is the only ETH movement out of this contract
 */
contract Grimoire is IGrimoire {
    // ────────────────────────────────────────────────────────────────────────
    // CONSTANTS
    // ────────────────────────────────────────────────────────────────────────

    uint256 public constant REBIND_FEE = 0.01 ether;
    uint256 public constant MAX_NAME_LENGTH = 32;

    // ────────────────────────────────────────────────────────────────────────
    // IMMUTABLES
    // ────────────────────────────────────────────────────────────────────────

    /// @notice the v4 hook — writes cast, dispel, fold events
    address public immutable CAULDRON;

    /// @notice the yield distributor — writes essence claim events
    address public immutable WELLSPRING;

    /// @notice the mim token — writes tier change events
    address public immutable MIM;

    // ────────────────────────────────────────────────────────────────────────
    // STORAGE
    // ────────────────────────────────────────────────────────────────────────

    /// @notice per-wallet records (internal storage; access via records() view)
    mapping(address => WizardRecord) internal _records;

    /// @notice reverse lookup for name uniqueness — empty string never resolves to a real holder
    mapping(string => address) public nameToAddress;

    /// @notice total wizards born (= next wizard number to assign)
    uint256 public totalWizards;

    /// @notice block at which the fold occurred (0 = not yet reached)
    uint64 public foldBlock;

    // ────────────────────────────────────────────────────────────────────────
    // EVENTS
    // ────────────────────────────────────────────────────────────────────────

    event WizardBorn(address indexed wallet, uint256 indexed wizardNumber, uint64 atBlock);
    event CastRecorded(address indexed wallet, uint256 mimMinted, uint256 capContribution, uint256 newBalance);
    event DispelRecorded(address indexed wallet, uint256 mimBurned, uint256 newBalance);
    event EssenceRecorded(address indexed wallet, uint256 amount, uint256 newLifetimeTotal);
    event TierAscended(address indexed wallet, uint8 oldTier, uint8 newTier, uint64 atBlock);
    event NameBound(address indexed wallet, string name, uint256 feePaid);
    event NameRebound(address indexed wallet, string oldName, string newName, uint256 feePaid);
    event WizardSealed(address indexed wallet, uint64 atBlock);

    // ────────────────────────────────────────────────────────────────────────
    // ERRORS
    // ────────────────────────────────────────────────────────────────────────

    error OnlyCauldron();
    error OnlyWellspring();
    error OnlyMIM();
    error InvalidAddress();
    error IncorrectRebindFee();
    error NameTooLong();
    error NameAlreadyTaken();
    error NameIsEmpty();
    error ReserveForwardFailed();
    error FoldAlreadySealed();
    error EmptyWalletArray();

    // ────────────────────────────────────────────────────────────────────────
    // MODIFIERS
    // ────────────────────────────────────────────────────────────────────────

    modifier onlyCauldron() {
        if (msg.sender != CAULDRON) revert OnlyCauldron();
        _;
    }

    modifier onlyWellspring() {
        if (msg.sender != WELLSPRING) revert OnlyWellspring();
        _;
    }

    modifier onlyMIM() {
        if (msg.sender != MIM) revert OnlyMIM();
        _;
    }

    // ────────────────────────────────────────────────────────────────────────
    // CONSTRUCTOR
    // ────────────────────────────────────────────────────────────────────────

    constructor(address _cauldron, address _wellspring, address _mim) {
        if (_cauldron == address(0)) revert InvalidAddress();
        if (_wellspring == address(0)) revert InvalidAddress();
        if (_mim == address(0)) revert InvalidAddress();
        CAULDRON = _cauldron;
        WELLSPRING = _wellspring;
        MIM = _mim;
    }

    // ────────────────────────────────────────────────────────────────────────
    // WRITES — restricted to authorized contracts
    // ────────────────────────────────────────────────────────────────────────

    /**
     * @notice record a cast (mint) event for a wallet
     * @dev only callable by Cauldron
     * @param holder the wallet that minted
     * @param mimMinted amount of MIM the wallet received
     * @param capReduction how much the cap shrunk because of this cast
     * @param newBalance wallet's MIM balance after the mint
     */
    function recordCast(
        address holder,
        uint256 mimMinted,
        uint256 capReduction,
        uint256 newBalance
    ) external onlyCauldron {
        WizardRecord storage rec = _records[holder];

        // First cast → assign wizard number
        if (rec.firstCastBlock == 0) {
            totalWizards++;
            rec.wizardNumber = uint64(totalWizards);
            rec.firstCastBlock = uint64(block.number);
            rec.tierStartBlock = uint64(block.number);
            emit WizardBorn(holder, totalWizards, uint64(block.number));
        }

        // Update cast counters (append-only)
        rec.lastCastBlock = uint64(block.number);
        rec.lifetimeCast += mimMinted;
        rec.capShrunkByYou += capReduction;

        // Update peak balance if this mint pushed them higher
        if (newBalance > rec.peakBalance) {
            rec.peakBalance = newBalance;
        }

        emit CastRecorded(holder, mimMinted, capReduction, newBalance);
    }

    /**
     * @notice record a dispel (burn) event for a wallet
     * @dev only callable by Cauldron
     * @param holder the wallet that burned
     * @param mimBurned amount of MIM the wallet burned
     * @param newBalance wallet's MIM balance after the burn
     */
    function recordDispel(
        address holder,
        uint256 mimBurned,
        uint256 newBalance
    ) external onlyCauldron {
        WizardRecord storage rec = _records[holder];

        // Update dispel counters (append-only)
        rec.lastCastBlock = uint64(block.number);
        rec.lifetimeDispelled += mimBurned;

        emit DispelRecorded(holder, mimBurned, newBalance);
    }

    /**
     * @notice record an essence (yield) claim for a wallet
     * @dev only callable by Wellspring
     */
    function recordEssenceClaim(address holder, uint256 amount) external onlyWellspring {
        WizardRecord storage rec = _records[holder];
        rec.lifetimeEssence += amount;
        emit EssenceRecorded(holder, amount, rec.lifetimeEssence);
    }

    /**
     * @notice record a tier change for a wallet
     * @dev only callable by MIM token contract
     * @dev called by MIM's transfer hook when a holder's tier shifts
     */
    function recordTierChange(address holder, uint8 newTier, uint64 atBlock) external onlyMIM {
        WizardRecord storage rec = _records[holder];

        // Skip if no actual change (defensive — MIM should already filter this)
        if (rec.currentTier == newTier) return;

        uint8 oldTier = rec.currentTier;
        rec.currentTier = newTier;
        rec.tierStartBlock = atBlock;

        emit TierAscended(holder, oldTier, newTier, atBlock);
    }

    /**
     * @notice seal a batch of wallets as having held through the fold
     * @dev only callable by Cauldron, only at the fold block, supports batching
     * @dev Cauldron is responsible for snapshotting the holders list off-chain and
     *      passing them to this function in chunks to avoid block gas limits
     * @param wallets the wallets to seal
     * @param foldBlockNumber the block at which the fold occurred (must be set once and consistent)
     */
    function sealWizardsInFold(address[] calldata wallets, uint64 foldBlockNumber) external onlyCauldron {
        if (wallets.length == 0) revert EmptyWalletArray();

        // First call sets foldBlock; subsequent calls must use the same value
        if (foldBlock == 0) {
            foldBlock = foldBlockNumber;
        } else if (foldBlock != foldBlockNumber) {
            // Sealing across batches must reference the same block
            revert FoldAlreadySealed();
        }

        for (uint256 i = 0; i < wallets.length; i++) {
            address w = wallets[i];
            WizardRecord storage rec = _records[w];

            // Only seal wallets that have actually cast at some point
            // (defensive — Cauldron should already filter, but we're permanent so we double-check)
            if (rec.firstCastBlock == 0) continue;
            if (rec.sealedInFold) continue;

            rec.sealedInFold = true;
            emit WizardSealed(w, foldBlockNumber);
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // PERMISSIONLESS WRITES
    // ────────────────────────────────────────────────────────────────────────

    /**
     * @notice bind a display name to your wallet
     * @dev costs REBIND_FEE (0.01 ETH), paid to Cauldron's reserve
     * @dev can rebind by calling again with a new name and paying the fee again
     * @dev names must be 1–32 bytes long and not already taken by another wallet
     * @dev the caller's wallet need not have ever cast — anyone can bind a name
     * @param name the display name to bind
     */
    function bindName(string calldata name) external payable {
        // Validate fee
        if (msg.value != REBIND_FEE) revert IncorrectRebindFee();

        // Validate name length
        bytes memory nameBytes = bytes(name);
        if (nameBytes.length == 0) revert NameIsEmpty();
        if (nameBytes.length > MAX_NAME_LENGTH) revert NameTooLong();

        // Check name not already taken (by any other wallet — same wallet rebinding to same name is wasteful but allowed)
        address existingOwner = nameToAddress[name];
        if (existingOwner != address(0) && existingOwner != msg.sender) {
            revert NameAlreadyTaken();
        }

        WizardRecord storage rec = _records[msg.sender];
        string memory oldName = rec.displayName;

        // Clear old name reverse-lookup if there was one
        if (bytes(oldName).length > 0) {
            delete nameToAddress[oldName];
        }

        // Set new name
        rec.displayName = name;
        nameToAddress[name] = msg.sender;

        // Forward fee to Cauldron reserve via low-level call
        // (Cauldron must have a payable receive() or fallback that accepts these contributions)
        (bool success, ) = CAULDRON.call{value: msg.value}("");
        if (!success) revert ReserveForwardFailed();

        // Emit appropriate event based on whether this is a first bind or a rebind
        if (bytes(oldName).length > 0) {
            emit NameRebound(msg.sender, oldName, name, msg.value);
        } else {
            emit NameBound(msg.sender, name, msg.value);
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // READS
    // ────────────────────────────────────────────────────────────────────────

    /// @notice return the full wizard record for a wallet
    function records(address holder) external view returns (WizardRecord memory) {
        return _records[holder];
    }

    /// @notice check if a wallet has ever cast
    function hasGrimoire(address holder) external view returns (bool) {
        return _records[holder].firstCastBlock != 0;
    }

    /// @notice convenience: get just the wizard number for a wallet
    function wizardNumberOf(address holder) external view returns (uint64) {
        return _records[holder].wizardNumber;
    }

    /// @notice convenience: get just the display name for a wallet
    function displayNameOf(address holder) external view returns (string memory) {
        return _records[holder].displayName;
    }

    /// @notice convenience: has the fold been reached?
    function foldReached() external view returns (bool) {
        return foldBlock != 0;
    }
}
