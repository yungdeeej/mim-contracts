// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UD60x18, ud, unwrap, exp, ln} from "@prb/math/UD60x18.sol";

/**
 * @title CauldronMath
 * @notice pure curve math for the gravity bonding curve
 * @dev separated from Cauldron for cleaner testing and gas-savings via pure functions
 *
 * Per SPEC §2 (curve math):
 *   q(e, t) = K(t) · (1 − e^(−e/S))
 *   p(e, t) = (S / K(t)) · e^(e/S)
 *   Δe(q, b) = S · ln((K(t) − q + b) / (K(t) − q))
 *   K(t) = K_INITIAL − γ · M(t)
 *
 * All values use PRBMath UD60x18 fixed-point (18 decimals).
 */
library CauldronMath {
    // ────────────────────────────────────────────────────────────────────────
    // CONSTANTS (mirrored from SPEC §14 — must match Cauldron's constants)
    // ────────────────────────────────────────────────────────────────────────

    uint256 internal constant K_INITIAL = 21_000_000e18;  // 21M MIM
    uint256 internal constant S = 500e18;                  // 500 ETH scale
    uint256 internal constant GAMMA = 0.5e18;              // 50% gravity coefficient

    // ────────────────────────────────────────────────────────────────────────
    // ERRORS
    // ────────────────────────────────────────────────────────────────────────

    error CapAlreadyConverged();
    error InsufficientSupplyForBurn();
    error MathOverflow();

    // ────────────────────────────────────────────────────────────────────────
    // CAP CALCULATION
    // ────────────────────────────────────────────────────────────────────────

    /// @notice compute the current cap given lifetime mints
    /// @dev K(t) = K_INITIAL - γ · M(t), but clamps to 0 if M(t) ≥ K_INITIAL/γ
    /// @param lifetimeMinted total tokens ever minted (M(t))
    /// @return cap current supply cap K(t)
    function currentCap(uint256 lifetimeMinted) internal pure returns (uint256 cap) {
        // K(t) = K_INITIAL - 0.5 * M(t)
        // Using UD60x18 fixed-point: gamma is 0.5e18, so gamma * M / 1e18 = 0.5 * M
        uint256 reduction = (GAMMA * lifetimeMinted) / 1e18;

        if (reduction >= K_INITIAL) {
            return 0;  // cap has converged to zero, no more mints possible
        }

        cap = K_INITIAL - reduction;
    }

    // ────────────────────────────────────────────────────────────────────────
    // FORWARD CURVE: q(e, t)
    // ────────────────────────────────────────────────────────────────────────

    /// @notice given cumulative ETH and current cap, compute the corresponding minted supply
    /// @dev q(e, t) = K(t) · (1 − e^(−e/S))
    /// @param ethCumulative total ETH ever deposited into the curve reserve
    /// @param cap the current cap K(t)
    /// @return supply the target circulating supply at this ETH position
    function supplyAtCumulativeETH(uint256 ethCumulative, uint256 cap) internal pure returns (uint256 supply) {
        if (cap == 0) return 0;

        // ratio = e / S (in UD60x18)
        UD60x18 ratio = ud(ethCumulative) / ud(S);

        // PRBMath exp overflows above ~133.08; at that ratio e^(-ratio) ≈ 0 so supply ≈ cap
        if (unwrap(ratio) >= 133e18) return cap;

        // expNeg = e^(-ratio); PRBMath doesn't have negative exponents directly,
        // so we compute exp(ratio) and use 1 / exp(ratio) = e^(-ratio)
        UD60x18 expPos = exp(ratio);

        // safety: if expPos somehow underflows to zero, treat result as cap (asymptotic limit)
        if (unwrap(expPos) == 0) return cap;

        // factor = 1 - e^(-e/S) = 1 - (1 / expPos)
        // To compute (1 - 1/expPos): multiply both sides by expPos to get (expPos - 1) / expPos
        UD60x18 one = ud(1e18);
        if (unwrap(expPos) <= unwrap(one)) return 0;  // shouldn't happen for ethCumulative > 0

        UD60x18 factor = (expPos - one) / expPos;

        // supply = cap * factor
        UD60x18 result = ud(cap) * factor / ud(1e18);
        supply = unwrap(result);

        // Clamp to cap (numerical safety)
        if (supply > cap) supply = cap;
    }

    // ────────────────────────────────────────────────────────────────────────
    // MARGINAL PRICE: p(e, t)
    // ────────────────────────────────────────────────────────────────────────

    /// @notice marginal mint price at a given cumulative ETH position
    /// @dev p(e, t) = (S / K(t)) · e^(e/S)
    /// @param ethCumulative current cumulative ETH in reserve
    /// @param cap current cap K(t)
    /// @return price marginal price in ETH per MIM (18 decimals)
    function marginalPrice(uint256 ethCumulative, uint256 cap) public pure returns (uint256 price) {
        if (cap == 0) revert CapAlreadyConverged();

        // ratio = e / S
        UD60x18 ratio = ud(ethCumulative) / ud(S);

        // expPos = e^(e/S)
        UD60x18 expPos = exp(ratio);

        // baseFactor = S / K
        UD60x18 baseFactor = ud(S) * ud(1e18) / ud(cap);

        // price = baseFactor * expPos
        UD60x18 result = baseFactor * expPos / ud(1e18);
        price = unwrap(result);
    }

    // ────────────────────────────────────────────────────────────────────────
    // MINT AMOUNT: how many tokens for a given ETH input
    // ────────────────────────────────────────────────────────────────────────

    /// @notice given an ETH input and current state, compute how many MIM to mint
    /// @dev computed as the delta between supplyAt(e + ethIn) and supplyAt(e)
    /// @param ethCumulativeBefore current cumulative ETH before this mint
    /// @param ethIn the ETH being deposited in this mint
    /// @param cap the current cap K(t) (note: this is the cap BEFORE applying gravity reduction
    ///        from THIS mint; gravity is applied in afterSwap)
    /// @return mintAmount_ the number of MIM to mint
    function mintAmount(
        uint256 ethCumulativeBefore,
        uint256 ethIn,
        uint256 cap
    ) internal pure returns (uint256 mintAmount_) {
        uint256 supplyBefore = supplyAtCumulativeETH(ethCumulativeBefore, cap);
        uint256 supplyAfter = supplyAtCumulativeETH(ethCumulativeBefore + ethIn, cap);

        if (supplyAfter <= supplyBefore) return 0;
        mintAmount_ = supplyAfter - supplyBefore;
    }

    // ────────────────────────────────────────────────────────────────────────
    // INVERSE CURVE: Δe(q, b) — burn returns
    // ────────────────────────────────────────────────────────────────────────

    /// @notice given a burn amount and current state, compute the ETH to return
    /// @dev Δe(q, b) = S · ln((K - q + b) / (K - q))
    /// @param currentSupply current circulating supply (q)
    /// @param burnAmount amount of MIM being burned (b)
    /// @param cap current cap K(t)
    /// @return ethOut the ETH to pay out for this burn
    function burnReturn(
        uint256 currentSupply,
        uint256 burnAmount,
        uint256 cap
    ) public pure returns (uint256 ethOut) {
        if (burnAmount == 0) return 0;
        if (currentSupply < burnAmount) revert InsufficientSupplyForBurn();
        if (currentSupply >= cap) revert CapAlreadyConverged();

        // (K - q) is the remaining "room" in the cap
        uint256 roomBefore = cap - currentSupply;
        // (K - q + b) is the room AFTER the burn (more room because supply decreases)
        uint256 roomAfter = cap - currentSupply + burnAmount;

        // ratio = roomAfter / roomBefore (will be > 1 since burnAmount > 0)
        UD60x18 ratio = ud(roomAfter) * ud(1e18) / ud(roomBefore);

        // logTerm = ln(ratio)
        UD60x18 logTerm = ln(ratio);

        // ethOut = S * logTerm
        UD60x18 result = ud(S) * logTerm / ud(1e18);
        ethOut = unwrap(result);
    }

    // ────────────────────────────────────────────────────────────────────────
    // RANDOM MULTIPLIER (anti-MEV defense in first 100 blocks)
    // ────────────────────────────────────────────────────────────────────────

    /// @notice compute a pseudo-random multiplier between 0.9× and 1.1×
    /// @dev Per SPEC Decision Log #22: keccak256(timestamp + prevrandao + sender + ethAmount)
    /// @dev returns a value in basis points (9000 = 0.9×, 10000 = 1.0×, 11000 = 1.1×)
    function randomMultiplierBps(
        uint256 timestamp,
        uint256 prevrandao,
        address sender,
        uint256 ethAmount
    ) internal pure returns (uint256 multiplierBps) {
        uint256 seed = uint256(keccak256(abi.encode(timestamp, prevrandao, sender, ethAmount)));
        // Map to range [9000, 11000] (a 2000-wide range)
        // seed % 2001 gives [0, 2000], + 9000 gives [9000, 11000]
        multiplierBps = 9000 + (seed % 2001);
    }
}
