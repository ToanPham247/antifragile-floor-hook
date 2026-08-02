// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {FloorMath} from "../src/lib/FloorMath.sol";

/**
 * @notice Unit + fuzz tests for the pure {FloorMath} library — the Antifragile Floor economics.
 *         No PoolManager, no chain state: floor math is isolated so it can be exhaustively fuzzed.
 *
 *         Conventions: WAD = 1e18 (floor price is QUOTE-per-TKN, 1e18-scaled), BPS = 10_000.
 */
contract FloorMathTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    // ------------------------------------------------------------------
    // floorPrice = QUOTE-per-TKN (1e18-scaled) = reserveQuote * WAD / backedSupply
    // ------------------------------------------------------------------

    function test_floorPrice_basic() public pure {
        // 100 QUOTE backing 1000 TKN => 0.1 QUOTE per TKN.
        assertEq(FloorMath.floorPrice(100e18, 1000e18), 0.1e18, "floorPrice(100e18,1000e18) != 0.1e18");
    }

    function test_floorPrice_zeroSupply() public pure {
        // No backed supply => undefined price => 0 (never divide by zero).
        assertEq(FloorMath.floorPrice(100e18, 0), 0, "floorPrice with zero supply != 0");
    }

    // ------------------------------------------------------------------
    // ratchet = monotonic high water mark (never decreases)
    // ------------------------------------------------------------------

    function test_ratchet_up() public pure {
        assertEq(FloorMath.ratchet(0.1e18, 0.2e18), 0.2e18, "ratchet up failed");
    }

    function test_ratchet_holds() public pure {
        // Candidate below current high => keep current high (never ratchet down).
        assertEq(FloorMath.ratchet(0.3e18, 0.2e18), 0.3e18, "ratchet should hold current high");
    }

    // ------------------------------------------------------------------
    // skim = bps of quote-side volume, floor-rounded
    // ------------------------------------------------------------------

    function test_skim_basic() public pure {
        // 20 bps of 1000 QUOTE = 2 QUOTE.
        assertEq(FloorMath.skim(1000e18, 20), 2e18, "skim(1000e18,20) != 2e18");
    }

    function test_skim_zeroBps() public pure {
        assertEq(FloorMath.skim(1000e18, 0), 0, "skim with 0 bps != 0");
    }

    // ------------------------------------------------------------------
    // honor = redeem TKN at floor, capped by available reserve
    // ------------------------------------------------------------------

    function test_honor_full() public pure {
        // 10 TKN at 0.1 floor = 1 QUOTE owed; reserve 5 covers it fully.
        (uint256 tknHonored, uint256 quoteOut) = FloorMath.honor(10e18, 0.1e18, 5e18);
        assertEq(tknHonored, 10e18, "honor full: tknHonored != 10e18");
        assertEq(quoteOut, 1e18, "honor full: quoteOut != 1e18");
    }

    function test_honor_reserveCapped() public pure {
        // 10 TKN wants 1 QUOTE but only 0.4 reserve => cap: pay 0.4 QUOTE, honor 4 TKN.
        (uint256 tknHonored, uint256 quoteOut) = FloorMath.honor(10e18, 0.1e18, 0.4e18);
        assertEq(tknHonored, 4e18, "honor capped: tknHonored != 4e18");
        assertEq(quoteOut, 0.4e18, "honor capped: quoteOut != 0.4e18");
    }

    function test_honor_zeroFloor() public pure {
        // No floor set => nothing honored.
        (uint256 tknHonored, uint256 quoteOut) = FloorMath.honor(10e18, 0, 5e18);
        assertEq(tknHonored, 0, "honor zero floor: tknHonored != 0");
        assertEq(quoteOut, 0, "honor zero floor: quoteOut != 0");
    }

    // ------------------------------------------------------------------
    // Fuzz invariants
    // ------------------------------------------------------------------

    /// @notice honor can never pay out more QUOTE than exists in reserve, nor honor more TKN than offered.
    function testFuzz_honor_never_exceeds_reserve(uint256 tknIn, uint256 floorPx, uint256 reserve) public pure {
        tknIn = bound(tknIn, 0, 1e30);
        floorPx = bound(floorPx, 0, 1e24);
        reserve = bound(reserve, 0, 1e30);

        (uint256 tknHonored, uint256 quoteOut) = FloorMath.honor(tknIn, floorPx, reserve);

        assertLe(quoteOut, reserve, "quoteOut exceeds reserve");
        assertLe(tknHonored, tknIn, "tknHonored exceeds tknIn");
    }

    /// @notice The high water mark never decreases: ratchet(a, b) >= a for all a, b.
    function testFuzz_ratchet_monotonic(uint256 a, uint256 b) public pure {
        assertGe(FloorMath.ratchet(a, b), a, "ratchet decreased below current high");
    }

    /// @notice With no backed supply the floor price is always 0 (no divide-by-zero).
    function testFuzz_floorPrice_zero_supply(uint256 reserveQuote) public pure {
        assertEq(FloorMath.floorPrice(reserveQuote, 0), 0, "floorPrice with zero supply != 0");
    }

    /// @notice Value-conservative: QUOTE paid out never exceeds what tknIn is worth at floor (tknIn*floorPx/WAD).
    function testFuzz_honor_never_overpays_value(uint256 tknIn, uint256 floorPx, uint256 reserve) public pure {
        tknIn = bound(tknIn, 0, 1e30);
        floorPx = bound(floorPx, 0, 1e24);
        reserve = bound(reserve, 0, 1e30);

        (, uint256 quoteOut) = FloorMath.honor(tknIn, floorPx, reserve);

        // Max value the offered TKN can be worth at floor. tknIn<=1e30, floorPx<=1e24 => product <=1e54, no overflow.
        uint256 maxOwedAtFloor = (tknIn * floorPx) / WAD;
        assertLe(quoteOut, maxOwedAtFloor, "honor overpaid beyond value at floor");
    }
}
