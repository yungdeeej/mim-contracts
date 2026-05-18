// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IGrimoire
 * @notice full interface for the Grimoire identity registry
 * @dev exposed for Cauldron, Wellspring, and MIM to call into Grimoire
 */
interface IGrimoire {
    // ─── Structs ───

    struct WizardRecord {
        uint64 wizardNumber;
        uint64 firstCastBlock;
        uint64 lastCastBlock;
        uint64 tierStartBlock;
        uint256 peakBalance;
        uint256 lifetimeCast;
        uint256 lifetimeDispelled;
        uint256 lifetimeEssence;
        uint256 capShrunkByYou;
        uint8 currentTier;
        bool sealedInFold;
        string displayName;
    }

    // ─── Writes (restricted) ───

    /// @notice called by Cauldron when a wallet mints MIM
    function recordCast(
        address holder,
        uint256 mimMinted,
        uint256 capReduction,
        uint256 newBalance
    ) external;

    /// @notice called by Cauldron when a wallet burns MIM
    function recordDispel(
        address holder,
        uint256 mimBurned,
        uint256 newBalance
    ) external;

    /// @notice called by Wellspring when a wallet claims yield
    function recordEssenceClaim(address holder, uint256 amount) external;

    /// @notice called by MIM token when a transfer changes a wallet's tier
    function recordTierChange(address holder, uint8 newTier, uint64 atBlock) external;

    /// @notice called by Cauldron exactly once, when supply meets the cap (the fold)
    function sealWizardsInFold(address[] calldata wallets, uint64 foldBlockNumber) external;

    // ─── Permissionless ───

    /// @notice bind a display name to your wallet — costs REBIND_FEE, paid to reserve
    function bindName(string calldata name) external payable;

    // ─── Reads ───

    function records(address holder) external view returns (WizardRecord memory);
    function totalWizards() external view returns (uint256);
    function nameToAddress(string calldata name) external view returns (address);
    function foldBlock() external view returns (uint64);
}
