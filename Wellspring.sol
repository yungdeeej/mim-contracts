// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IWellspring} from "./interfaces/IWellspring.sol";
import {IGrimoire} from "./interfaces/IGrimoire.sol";

/**
 * @title Wellspring
 * @notice the merkle-based eth yield distributor for magic internet money
 * @dev
 *   - receives eth from Cauldron's harvest() (lido yield converted to eth)
 *   - keeper posts merkle roots representing yield distribution snapshots
 *   - holders claim their share by submitting (amount, proof) against a root
 *   - all roots are preserved forever — past distributions stay claimable
 *   - notifies Grimoire on every successful claim
 *
 *   The "no operator" guarantee:
 *   - keeper can ONLY post roots — cannot send eth, modify roots, or extract value
 *   - past roots can never be invalidated
 *   - eth deposits are accepted from anyone (defensive — primarily Cauldron)
 *   - reentrancy guard on all eth-sending paths
 *
 *   Merkle root construction (handled off-chain by keeper):
 *   - leaf = keccak256(abi.encodePacked(holder, amount))
 *   - each holder appears exactly once per root
 *   - amount is calculated as (balance × multiplier) / Σ(balance × multiplier) × totalETHForRoot
 *   - keeper publishes the full leaves list off-chain (IPFS) so holders can construct proofs
 */
contract Wellspring is IWellspring, ReentrancyGuard {
    // ────────────────────────────────────────────────────────────────────────
    // IMMUTABLES
    // ────────────────────────────────────────────────────────────────────────

    /// @notice the v4 hook — primary depositor (other depositors also allowed)
    address public immutable CAULDRON;

    /// @notice the off-chain keeper that posts merkle roots
    /// @dev this is the ONLY trusted role in the protocol, and only for non-financial action
    address public immutable KEEPER;

    /// @notice the identity registry — notified on every claim
    address public immutable GRIMOIRE;

    // ────────────────────────────────────────────────────────────────────────
    // STORAGE
    // ────────────────────────────────────────────────────────────────────────

    /// @notice append-only list of every posted merkle root
    MerkleRoot[] internal _roots;

    /// @notice claimed[rootIndex][holder] — true if holder has claimed against this root
    mapping(uint256 => mapping(address => bool)) internal _claimed;

    /// @notice running total of ETH received across all deposits
    uint256 public totalETHReceived;

    /// @notice running total of ETH claimed by holders
    uint256 public totalETHClaimed;

    // ────────────────────────────────────────────────────────────────────────
    // EVENTS
    // ────────────────────────────────────────────────────────────────────────

    event RootPosted(uint256 indexed rootIndex, bytes32 root, uint256 totalETH, uint64 atBlock);
    event Deposited(address indexed from, uint256 amount, uint256 newTotalReceived);
    event Claimed(address indexed holder, uint256 indexed rootIndex, uint256 amount);

    // ────────────────────────────────────────────────────────────────────────
    // ERRORS
    // ────────────────────────────────────────────────────────────────────────

    error OnlyKeeper();
    error InvalidAddress();
    error InvalidRootIndex();
    error AlreadyClaimed();
    error InvalidProof();
    error ZeroAmount();
    error ZeroDeposit();
    error TransferFailed();
    error ArrayLengthMismatch();
    error EmptyClaim();

    // ────────────────────────────────────────────────────────────────────────
    // MODIFIERS
    // ────────────────────────────────────────────────────────────────────────

    modifier onlyKeeper() {
        if (msg.sender != KEEPER) revert OnlyKeeper();
        _;
    }

    // ────────────────────────────────────────────────────────────────────────
    // CONSTRUCTOR
    // ────────────────────────────────────────────────────────────────────────

    constructor(address _cauldron, address _keeper, address _grimoire) {
        if (_cauldron == address(0)) revert InvalidAddress();
        if (_keeper == address(0)) revert InvalidAddress();
        if (_grimoire == address(0)) revert InvalidAddress();
        CAULDRON = _cauldron;
        KEEPER = _keeper;
        GRIMOIRE = _grimoire;
    }

    // ────────────────────────────────────────────────────────────────────────
    // KEEPER: POST ROOT
    // ────────────────────────────────────────────────────────────────────────

    /**
     * @notice post a new Merkle root for yield distribution
     * @dev only callable by KEEPER
     * @dev the totalETH parameter is informational — the contract does not verify it
     *      matches the actual leaves sum. that's by design: the keeper publishes
     *      leaves off-chain (e.g. IPFS) and holders verify the math themselves.
     * @param root the merkle root of (holder, amount) leaves
     * @param totalETH the total ETH represented by this root (for transparency, not validation)
     */
    function postRoot(bytes32 root, uint256 totalETH) external onlyKeeper {
        _roots.push(MerkleRoot({
            root: root,
            postedAtBlock: uint64(block.number),
            totalETHForThisRoot: totalETH
        }));

        emit RootPosted(_roots.length - 1, root, totalETH, uint64(block.number));
    }

    // ────────────────────────────────────────────────────────────────────────
    // DEPOSITS
    // ────────────────────────────────────────────────────────────────────────

    /**
     * @notice accept ETH deposits
     * @dev primarily called by Cauldron during harvest, but anyone can contribute
     * @dev no state changes besides counter — eth waits for keeper to post roots
     */
    function deposit() external payable {
        if (msg.value == 0) revert ZeroDeposit();
        totalETHReceived += msg.value;
        emit Deposited(msg.sender, msg.value, totalETHReceived);
    }

    /// @notice fallback receive — same as deposit() but no event check
    /// @dev allows Cauldron to send ETH via plain transfer; tracks it the same way
    receive() external payable {
        if (msg.value > 0) {
            totalETHReceived += msg.value;
            emit Deposited(msg.sender, msg.value, totalETHReceived);
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // CLAIMS
    // ────────────────────────────────────────────────────────────────────────

    /**
     * @notice claim your share of yield against a specific Merkle root
     * @param rootIndex which root to claim against (most recent = rootCount() - 1)
     * @param amount the amount of ETH claimable for msg.sender per this root's leaves
     * @param proof the Merkle proof for (msg.sender, amount)
     */
    function claim(uint256 rootIndex, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        _processClaim(msg.sender, rootIndex, amount, proof);
    }

    /**
     * @notice batch-claim across multiple roots in one transaction
     * @dev arrays must be parallel and same length; reverts entire tx if any single claim fails
     */
    function claimMultiple(
        uint256[] calldata rootIndices,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external nonReentrant {
        if (rootIndices.length == 0) revert EmptyClaim();
        if (rootIndices.length != amounts.length) revert ArrayLengthMismatch();
        if (rootIndices.length != proofs.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < rootIndices.length; i++) {
            _processClaim(msg.sender, rootIndices[i], amounts[i], proofs[i]);
        }
    }

    /// @dev internal claim logic, called by claim() and claimMultiple()
    /// @dev caller must be reentrancy-protected externally
    function _processClaim(
        address holder,
        uint256 rootIndex,
        uint256 amount,
        bytes32[] calldata proof
    ) internal {
        // ─── Checks ───
        if (rootIndex >= _roots.length) revert InvalidRootIndex();
        if (amount == 0) revert ZeroAmount();
        if (_claimed[rootIndex][holder]) revert AlreadyClaimed();

        // Standard merkle leaf: keccak256(abi.encodePacked(holder, amount))
        // Note: we use abi.encodePacked deliberately; the keeper MUST construct
        // leaves identically off-chain to produce valid proofs
        bytes32 leaf = keccak256(abi.encodePacked(holder, amount));

        if (!MerkleProof.verify(proof, _roots[rootIndex].root, leaf)) {
            revert InvalidProof();
        }

        // ─── Effects ───
        _claimed[rootIndex][holder] = true;
        totalETHClaimed += amount;

        // ─── Interactions ───
        // Notify Grimoire BEFORE sending ETH so the record is in place even if transfer succeeds
        // Use low-level call so Grimoire failure doesn't trap the claim — events are canonical
        bytes memory data = abi.encodeWithSignature(
            "recordEssenceClaim(address,uint256)",
            holder,
            amount
        );
        (bool grimoireSuccess, ) = GRIMOIRE.call{gas: 100_000}(data);
        // Intentionally ignore grimoireSuccess — event log is the canonical record
        grimoireSuccess;

        // Send ETH last (CEI pattern + reentrancy guard at outer level)
        (bool success, ) = holder.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit Claimed(holder, rootIndex, amount);
    }

    // ────────────────────────────────────────────────────────────────────────
    // READS
    // ────────────────────────────────────────────────────────────────────────

    function roots(uint256 index) external view returns (MerkleRoot memory) {
        if (index >= _roots.length) revert InvalidRootIndex();
        return _roots[index];
    }

    function rootCount() external view returns (uint256) {
        return _roots.length;
    }

    function claimed(uint256 rootIndex, address holder) external view returns (bool) {
        return _claimed[rootIndex][holder];
    }

    /// @notice check if a holder can claim a specific (rootIndex, amount) with given proof
    /// @dev pure verification helper; does not check `_claimed` status
    function verifyProof(
        uint256 rootIndex,
        address holder,
        uint256 amount,
        bytes32[] calldata proof
    ) external view returns (bool) {
        if (rootIndex >= _roots.length) return false;
        bytes32 leaf = keccak256(abi.encodePacked(holder, amount));
        return MerkleProof.verify(proof, _roots[rootIndex].root, leaf);
    }

    /// @notice total ETH currently sitting in the contract (received - claimed)
    /// @dev accounting view; actual balance may differ if anyone sent eth via selfdestruct
    function pendingDistribution() external view returns (uint256) {
        return totalETHReceived - totalETHClaimed;
    }

    /// @notice contract's actual ETH balance (for sanity checking)
    function actualBalance() external view returns (uint256) {
        return address(this).balance;
    }
}
