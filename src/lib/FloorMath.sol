// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title FloorMath
 * @notice Pure economics of the Antifragile Floor — with no chain state, so it can be exhaustively
 *         fuzz-tested in isolation (no PoolManager, no hook, no storage).
 *
 * @dev Model:
 *      - QUOTE reserve `R` backs a TKN supply `S`.
 *      - Floor price is QUOTE-per-TKN, 1e18-scaled (WAD): `R * WAD / S`.
 *      - The floor is monotonic — it ratchets up only, never down.
 *      - A per-swap `skim` (bps of quote-side volume) funds the reserve.
 *      - On a sell, `honor` returns how much TKN can be redeemed at the floor, capped by the
 *        available reserve (the floor never promises more QUOTE than it actually holds).
 *
 *      All functions are `internal pure`: this is a link-free library that inlines at its call sites.
 */
library FloorMath {
    /// @dev Fixed-point scale for prices (1e18).
    uint256 internal constant WAD = 1e18;

    /// @dev Basis-points denominator (10_000).
    uint256 internal constant BPS = 10_000;

    /**
     * @notice Floor price = QUOTE per TKN, 1e18-scaled.
     * @param reserveQuote QUOTE reserve backing the supply (`R`).
     * @param backedSupply TKN supply that is backed (`S`).
     * @return QUOTE-per-TKN at floor, WAD-scaled; `0` when there is no backed supply.
     * @dev Floor-rounded (Solidity integer division). Zero supply returns 0 to avoid divide-by-zero.
     */
    function floorPrice(uint256 reserveQuote, uint256 backedSupply) internal pure returns (uint256) {
        if (backedSupply == 0) return 0;
        return (reserveQuote * WAD) / backedSupply;
    }

    /**
     * @notice Monotonic high-water mark: return the greater of the current high and a new candidate.
     * @param currentHigh The current floor high (never decreased).
     * @param candidate A proposed new floor.
     * @return The ratcheted floor — `candidate` only if it is strictly greater, else `currentHigh`.
     */
    function ratchet(uint256 currentHigh, uint256 candidate) internal pure returns (uint256) {
        return candidate > currentHigh ? candidate : currentHigh;
    }

    /**
     * @notice Skim a bps cut of quote-side volume to fund the reserve.
     * @param quoteAmount The quote-side volume of the swap.
     * @param bps The skim rate in basis points (of {BPS} = 10_000).
     * @return The skimmed QUOTE amount, floor-rounded.
     */
    function skim(uint256 quoteAmount, uint256 bps) internal pure returns (uint256) {
        return (quoteAmount * bps) / BPS;
    }

    /**
     * @notice How much TKN can be redeemed at the floor, capped by the available reserve.
     * @param tknIn TKN offered for redemption at the floor.
     * @param floorPx Current floor price (QUOTE per TKN, WAD-scaled).
     * @param reserve Available QUOTE reserve to pay redemptions.
     * @return tknHonored TKN actually redeemed at the floor.
     * @return quoteOut QUOTE paid out for the redeemed TKN.
     * @dev No floor (`floorPx == 0`) or nothing offered (`tknIn == 0`) => `(0, 0)`.
     *      Otherwise the QUOTE owed is `tknIn * floorPx / WAD`:
     *        - if the reserve covers it, honor everything: `(tknIn, quoteOwed)`;
     *        - else pay out the whole reserve and honor only the TKN it can cover:
     *          `quoteOut = reserve`, `tknHonored = reserve * WAD / floorPx` (floor-rounded).
     *      Floor-rounding `tknHonored` keeps the payout value-conservative: `quoteOut` never exceeds
     *      the value of the honored TKN at floor, and `quoteOut` never exceeds `reserve`.
     */
    function honor(uint256 tknIn, uint256 floorPx, uint256 reserve)
        internal
        pure
        returns (uint256 tknHonored, uint256 quoteOut)
    {
        if (floorPx == 0 || tknIn == 0) return (0, 0);

        uint256 quoteOwed = (tknIn * floorPx) / WAD;
        if (quoteOwed <= reserve) {
            return (tknIn, quoteOwed);
        }

        // Reserve-capped: pay out everything we hold, honor only the TKN the reserve can cover.
        quoteOut = reserve;
        tknHonored = (reserve * WAD) / floorPx;
    }
}
