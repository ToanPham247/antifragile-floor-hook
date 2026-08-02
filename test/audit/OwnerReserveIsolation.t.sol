// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AuditBase} from "./AuditBase.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {AntifragileFloorHook} from "../../src/AntifragileFloorHook.sol";

/**
 * @title OwnerReserveIsolation
 * @notice AUDIT — Vector 2 (fee custody) × Vector 1 (reserve). Proves the two pots are strictly isolated:
 *
 *   • The OWNER's only lever is `claimProgrammableFee`, which touches ONLY `programmableFeeOwed` (the
 *     platform liability). It can NEVER reduce `reserveQuote` — not with `currency == quote`, not with a
 *     different currency, not with a bogus pool. The floor reserve is not owner-withdrawable by design.
 *
 *   • Symmetrically, the floor top-up burns ONLY `reserveQuote`; even a fully-drained reserve leaves the
 *     platform liability 100% backed and claimable (also shown in TokenModel's admin-burn PoC).
 *
 *   • There is no external mutator of `reserveQuote` at all: the reserve rises only from the project fee
 *     slice and falls only through a below-floor exact-input sell top-up.
 */
contract OwnerReserveIsolation is AuditBase {
    function setUp() public {
        _setUpManager();
    }

    /* ================================================================== */
    /*  The owner cannot extract or reduce the floor reserve, ever.          */
    /* ================================================================== */

    function test_ownerClaimNeverReducesReserve() public {
        _mkTokens(3000e18, false);
        AntifragileFloorHook h = _deployHook(3000); // 30% -> big project slice into the reserve
        (PoolKey memory key, PoolId id) = _init(h);

        _seedReserve(key, 1000e18);
        uint256 reserve = h.reserveQuote();
        uint256 owed = h.programmableFeeOwed(id, quote);
        assertGt(reserve, 0, "need a reserve");
        assertGt(owed, 0, "need a liability");

        // (a) claim the platform liability -> pays exactly `owed`, reserve UNTOUCHED.
        vm.prank(OWNER);
        h.claimProgrammableFee(id, quote, makeAddr("d1"));
        assertEq(h.reserveQuote(), reserve, "owner claim reduced the reserve");
        assertEq(h.programmableFeeOwed(id, quote), 0, "liability not zeroed");
        assertEq(_quoteBal(h), reserve, "only the reserve should remain backing claims");

        // (b) claim again (owed now 0) -> no-op, reserve still untouched.
        vm.prank(OWNER);
        h.claimProgrammableFee(id, quote, makeAddr("d2"));
        assertEq(h.reserveQuote(), reserve, "second claim reduced the reserve");

        // (c) claim under the TKN currency or a bogus pool -> both 0, reserve untouched, no payout.
        vm.prank(OWNER);
        h.claimProgrammableFee(id, tkn, makeAddr("d3"));
        vm.prank(OWNER);
        h.claimProgrammableFee(PoolId.wrap(keccak256("bogus")), quote, makeAddr("d4"));
        assertEq(h.reserveQuote(), reserve, "cross-currency / bogus-pool claim reduced the reserve");
        _assertSolvent(h, id);
    }

    /* ================================================================== */
    /*  Draining the reserve to zero leaves the platform liability payable.  */
    /* ================================================================== */

    function test_reserveDrainToZero_leavesLiabilityFullyBacked() public {
        _mkTokens(3000e18, false);
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);

        _seedReserve(key, 1000e18);
        // Inflate supply so floorHigh (monotonic) sits far above the collapsed floor price, then a big
        // below-floor sell drains the WHOLE post-fee reserve (partial honor), exactly as in FloorHonor #3.
        MockERC20(Currency.unwrap(tkn)).mint(address(this), 7000e18);
        _modLiq(key, -(FULL_LIQ - int256(1e18)));

        Rec memory r = _swap(h, key, id, true, -int256(6000e18));
        assertTrue(r.toppedUp, "expected a draining top-up");
        assertEq(h.reserveQuote(), 0, "reserve should be drained to zero");

        // The platform liability is STILL fully backed and claimable despite the reserve being empty.
        uint256 owed = h.programmableFeeOwed(id, quote);
        assertGt(owed, 0, "need a surviving liability");
        assertEq(_quoteBal(h), owed, "claims must back exactly the liability once reserve is 0");
        address dest = makeAddr("ownerDest");
        vm.prank(OWNER);
        h.claimProgrammableFee(id, quote, dest);
        assertEq(MockERC20(Currency.unwrap(quote)).balanceOf(dest), owed, "liability not fully payable after drain");
        _assertSolvent(h, id);
    }

    /* ================================================================== */
    /*  No caller (owner or stranger) can grow/redirect the reserve; a buy   */
    /*  only grows it by the project fee, a claim never touches it.          */
    /* ================================================================== */

    function test_noExternalReserveMutator() public {
        _mkTokens(3000e18, false);
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);
        _seedReserve(key, 500e18);
        uint256 reserve = h.reserveQuote();

        // A stranger cannot claim (NotOwner) — no path to move reserve or liability.
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(AntifragileFloorHook.NotOwner.selector);
        h.claimProgrammableFee(id, quote, makeAddr("stranger"));
        assertEq(h.reserveQuote(), reserve, "stranger moved the reserve");

        // A buy grows the reserve by exactly its project slice (no more, no less).
        Rec memory buy = _swap(h, key, id, false, -int256(10e18));
        assertEq(h.reserveQuote(), reserve + buy.project, "reserve != prev + project");
        assertFalse(buy.toppedUp, "buy must not top up");
        _assertSolvent(h, id);
    }
}
