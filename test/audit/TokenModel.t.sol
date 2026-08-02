// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AuditBase} from "./AuditBase.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {AntifragileFloorHook} from "../../src/AntifragileFloorHook.sol";
import {FloorMath} from "../../src/lib/FloorMath.sol";

/**
 * @title TokenModelBoundary
 * @notice AUDIT — Vector 1 (floor / reserve economics under a non-standard TKN).
 *
 * The floor price is `reserveQuote * 1e18 / backedSupply` where `backedSupply` is an IMMUTABLE SNAPSHOT of
 * the TKN `totalSupply()` captured ONCE at bind time ({AntifragileFloorHook.backedSupplySnapshot}). The
 * floor path never re-reads `totalSupply()`, so a TKN whose supply can MOVE post-init
 * (mintable / burnable-anyone / rebasing) can NO LONGER move `floorHigh` — this is the hardening that
 * closes audit finding 1.2. This suite proves the boundary:
 *
 *   • FIX BOUND (holds for ALL tokens, standard or hostile): the reserve-funded top-up on any single
 *     sell is <= floorHigh * EXECUTED_tkn / 1e18 (+1 wei ceil). The reserve outflow is always bounded by
 *     the floor-value of the TKN actually delivered — this is the cd2109a fix and it never regresses.
 *
 *   • FLOOR IMMUNE TO POST-INIT SUPPLY (the finding-1.2 hardening): mint-after-init and burn-after-init
 *     (including admin burn-ANYONE / negative rebase that craters *other* holders) leave `floorHigh`
 *     driven ONLY by the frozen snapshot. A fractional holder can no longer crater `totalSupply` to spike
 *     the floor and over-extract the reserve; their redemption is bounded to the fair value of the TKN
 *     they deliver at the SNAPSHOT floor, and the reserve is not drained beyond that. Solvency and the
 *     platform liability are preserved in every case (as before).
 *
 *   • CANONICAL (fixed-supply TKN): snapshot == live, so the floor value is honest and unchanged.
 */
contract TokenModelBoundary is AuditBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpManager();
    }

    function _execTknIn(Rec memory r) internal pure returns (uint256) {
        return r.tknDelta < 0 ? uint256(int256(-r.tknDelta)) : 0;
    }

    /* ================================================================== */
    /*  Burning your OWN supply post-init CANNOT move the floor: it is       */
    /*  driven only by the immutable snapshot. Top-up stays bounded to the   */
    /*  fair value of the executed tkn at the SNAPSHOT floor; solvency holds. */
    /* ================================================================== */

    function test_burnOwnSupply_topUpBoundedByExecutedFairValue() public {
        _mkTokens(10_000e18, false); // quote = currency1; big supply so we hold plenty to burn
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);

        // Snapshot is frozen at bind time = the supply then (10_000 TKN).
        uint256 snap = h.backedSupplySnapshot();
        assertEq(snap, 10_000e18, "snapshot must equal the supply at bind time");

        _seedReserve(key, 1000e18);
        uint256 floorBefore = h.floorHigh();
        assertGt(floorBefore, 0, "floor not grown");

        // Thin the pool so a sell prices below the floor (a top-up will fire).
        _modLiq(key, -(FULL_LIQ - int256(1e18)));

        // Burn a big chunk of our OWN holdings -> LIVE totalSupply craters 10_000 -> 3_000. Pre-hardening
        // this would ratchet floorHigh UP; post-hardening the floor reads only the frozen snapshot.
        MockERC20(Currency.unwrap(tkn)).burn(address(this), 7000e18);
        assertEq(MockERC20(Currency.unwrap(tkn)).totalSupply(), 3000e18, "live supply should have cratered");

        Rec memory r = _swap(h, key, id, true, -int256(500e18));
        uint256 exec = _execTknIn(r);
        uint256 floorNow = h.floorHigh();

        // FLOOR IMMUNE: driven ONLY by the snapshot, never the cratered live supply. It moved at most by
        // this sell's fee accrual (candidate = (reserveBefore + project)/snapshot), NOT by the burn.
        assertEq(floorNow, FloorMath.floorPrice(r.reserveBefore + r.project, snap), "floor must be snapshot-driven");
        // Contrast: the cratered LIVE supply WOULD have spiked the floor > 3x (the pre-hardening primitive).
        uint256 wouldBeSpiked = FloorMath.floorPrice(r.reserveBefore + r.project, 3000e18);
        assertGt(wouldBeSpiked, floorNow * 3, "live-supply floor would have spiked > 3x the snapshot floor");

        // THE FIX BOUND still holds: the reserve subsidy never exceeds the floor-value of the EXECUTED tkn.
        uint256 fairAtSnapshotFloor = (floorNow * exec) / WAD;
        assertLe(r.topUp, fairAtSnapshotFloor + 1, "top-up exceeded fair value of executed tkn @ snapshot floor");

        // Reserve conservation: the ONLY reserve outflow is that bounded top-up.
        assertEq(r.reserveAfter, r.reserveBefore + r.project - r.topUp, "reserve accounting off");
        _assertSolvent(h, id);
    }

    /* ================================================================== */
    /*  FINDING 1.2 — MITIGATED BY IMMUTABLE SNAPSHOT: admin burn-ANYONE can  */
    /*  no longer spike the floor. A fractional holder who craters the LIVE   */
    /*  supply sees the floor unchanged (snapshot-driven); their redemption   */
    /*  is bounded to the fair value of the executed tkn at the snapshot      */
    /*  floor, and the reserve is NOT over-extracted. Solvency + liability    */
    /*  preserved (as before).                                               */
    /* ================================================================== */

    function test_adminBurnAnyone_mitigatedByImmutableSnapshot_noOverExtraction() public {
        // Plain MockERC20: its `burn(from,amount)` is UNAUTHENTICATED (== admin burn-anyone), the exact
        // primitive finding 1.2 abused. quote = currency1.
        _mkTokens(5000e18, false);
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);

        // The floor's denominator is FROZEN at bind time = 5000 TKN.
        uint256 snap = h.backedSupplySnapshot();
        assertEq(snap, 5000e18, "snapshot must equal the supply at bind time");

        _seedReserve(key, 1000e18);
        uint256 floorLegit = h.floorHigh(); // the honest floor before any manipulation
        assertGt(floorLegit, 0, "floor not grown");

        // Thin the pool: models a DUMP where spot has fallen below the floor — the floor's use case.
        _modLiq(key, -(FULL_LIQ - int256(1e18)));

        // Keep a small attacker bag; move the rest of the circulating supply to an innocent "victim",
        // then crater LIVE totalSupply by burning the VICTIM's tokens (attacker's own bag untouched).
        uint256 attackerBag;
        {
            address victim = makeAddr("victim");
            uint256 sendToVictim = MockERC20(Currency.unwrap(tkn)).balanceOf(address(this)) - 50e18;
            MockERC20(Currency.unwrap(tkn)).transfer(victim, sendToVictim);
            attackerBag = MockERC20(Currency.unwrap(tkn)).balanceOf(address(this));
            MockERC20(Currency.unwrap(tkn)).burn(victim, MockERC20(Currency.unwrap(tkn)).balanceOf(victim));
        }
        uint256 liveSupplyAfterBurn = MockERC20(Currency.unwrap(tkn)).totalSupply();
        assertLt(liveSupplyAfterBurn, snap / 50, "live supply should have cratered ~100x");

        uint256 reserveBefore = h.reserveQuote();
        uint256 owedBefore = h.programmableFeeOwed(id, quote);

        // Attacker redeems their unchanged bag; the floor no longer moves with the cratered LIVE supply.
        Rec memory r = _swap(h, key, id, true, -int256(attackerBag));
        uint256 exec = _execTknIn(r);
        uint256 floorNow = h.floorHigh();

        // What the ATTACK WOULD have produced pre-hardening (live cratered supply as the denominator):
        uint256 wouldBeSpikedFloor = FloorMath.floorPrice(reserveBefore + r.project, liveSupplyAfterBurn);
        uint256 fairAtSnapshotFloor = (floorNow * exec) / WAD;

        emit log_named_uint("snapshot supply (frozen)  ", snap);
        emit log_named_uint("live supply after burn    ", liveSupplyAfterBurn);
        emit log_named_uint("floorLegit  (honest)      ", floorLegit);
        emit log_named_uint("floorNow    (post-burn)   ", floorNow);
        emit log_named_uint("floor WOULD spike to (live)", wouldBeSpikedFloor);
        emit log_named_uint("executed TKN sold         ", exec);
        emit log_named_uint("reserveBefore attack      ", reserveBefore);
        emit log_named_uint("topUp (bounded, fair)     ", r.topUp);
        emit log_named_uint("fair value @ snapshot floor", fairAtSnapshotFloor);
        emit log_named_uint("reserveAfter attack       ", r.reserveAfter);

        // (1) FLOOR UNCHANGED FROM THE SNAPSHOT-BASED VALUE: driven ONLY by the frozen snapshot, so it moved
        //     at most by this sell's fee accrual — NOT by the supply crater. No ~99x spike.
        assertEq(floorNow, FloorMath.floorPrice(reserveBefore + r.project, snap), "floor must be snapshot-driven");
        assertLt(floorNow, floorLegit * 2, "floor must NOT spike from the supply crater (immune via snapshot)");
        // The primitive still exists off-hook: the cratered supply WOULD have spiked the floor >10x.
        assertGt(wouldBeSpikedFloor, floorNow * 10, "cratered live supply would have spiked the floor >10x");

        // (2) REDEMPTION BOUNDED TO FAIR VALUE at the snapshot floor (no over-extraction).
        assertLe(r.topUp, fairAtSnapshotFloor + 1, "top-up beyond fair value @ snapshot floor");
        assertLt(r.topUp, reserveBefore / 10, "redemption must be a small slice, not a reserve drain");

        // (3) RESERVE NOT DRAINED beyond that fair value — it is barely touched (contrast the pre-fix ~98%).
        assertGe(r.reserveAfter, reserveBefore - fairAtSnapshotFloor, "reserve drained beyond fair value");
        assertGe(r.reserveAfter, (reserveBefore * 9) / 10, "reserve materially drained => not mitigated");

        // SOLVENCY preserved, PLATFORM LIABILITY untouched, and still fully claimable.
        _assertSolvent(h, id);
        assertEq(h.programmableFeeOwed(id, quote), owedBefore + r.platform, "platform liability corrupted");
        _assertLiabilityFullyPayable(h, id);
    }

    /// @dev The owner can claim the FULL platform liability even after the floor reserve has been raided.
    function _assertLiabilityFullyPayable(AntifragileFloorHook h, PoolId id) internal {
        uint256 owed = h.programmableFeeOwed(id, quote);
        assertGt(owed, 0, "need a liability to prove it survives");
        address dest = makeAddr("ownerDest");
        vm.prank(OWNER);
        h.claimProgrammableFee(id, quote, dest);
        assertEq(MockERC20(Currency.unwrap(quote)).balanceOf(dest), owed, "platform liability not fully payable after drain");
        _assertSolvent(h, id);
    }

    /* ================================================================== */
    /*  Supply INFLATION (mint) cannot drain the reserve. Post-hardening the  */
    /*  floor ignores the inflated LIVE supply entirely (snapshot-driven),    */
    /*  and a buy / tiny above-spot sell still pays no subsidy.               */
    /* ================================================================== */

    function test_mintInflateSupply_noDrain_floorMonotonic() public {
        _mkTokens(3000e18, false);
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);

        _seedReserve(key, 1000e18);
        uint256 floorBefore = h.floorHigh();
        uint256 reserveBefore = h.reserveQuote();

        // Inflate LIVE supply massively -> the floor path ignores it (denominator is the frozen snapshot),
        // so floorHigh cannot be moved down by the inflation and the reserve cannot be drained by it.
        MockERC20(Currency.unwrap(tkn)).mint(address(this), 1_000_000e18);

        // A buy + a small in-range sell: neither may reduce the reserve below its pre-inflation level
        // (a buy never tops up; a small sell above the collapsed spot pays no subsidy).
        Rec memory buy = _swap(h, key, id, false, -int256(10e18));
        assertFalse(buy.toppedUp, "buy topped up");
        Rec memory sell = _swap(h, key, id, true, -int256(1e15));
        assertFalse(sell.toppedUp, "tiny sell after inflation topped up");

        assertGe(h.floorHigh(), floorBefore, "floorHigh decreased on inflation");
        assertGe(h.reserveQuote(), reserveBefore, "reserve drained by supply inflation");
        _assertSolvent(h, id);
    }

    /* ================================================================== */
    /*  A TKN whose totalSupply() REVERTS post-init can NO LONGER brick swaps: */
    /*  the floor path never calls totalSupply() (it reads the snapshot). The  */
    /*  snapshot was captured at bind time while totalSupply() still worked,   */
    /*  so the below-floor sell + top-up run fine and stay solvent. This is a   */
    /*  bonus of the finding-1.2 hardening (also closes the old 4.5 DoS).      */
    /* ================================================================== */

    function test_revertingTotalSupply_cannotBrickSwaps_snapshotImmune() public {
        HostileSupplyToken evil = new HostileSupplyToken();
        MockERC20 good = new MockERC20("GOOD", "GD", 18);
        // TKN = hostile, QUOTE = good. Its `mint` sets _supply, so the bind-time snapshot is well-defined.
        evil.mint(address(this), 3000e18);
        _useTokens(MockERC20(address(evil)), good, false, 3000e18);
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);

        // Snapshot captured at bind while totalSupply() still works (3000 minted here + 3000 via _useTokens).
        uint256 snap = h.backedSupplySnapshot();
        assertGt(snap, 0, "snapshot must be captured at bind time");

        _seedReserve(key, 500e18);
        uint256 floorAtSnapshot = h.floorHigh();
        assertGt(floorAtSnapshot, 0, "floor not grown");
        _modLiq(key, -(FULL_LIQ - int256(1e18))); // thin => the sell prices below the floor (top-up fires)

        // Arm the DoS: totalSupply() now reverts. Pre-hardening this reverted every swap (old finding 4.5);
        // post-hardening the floor path never touches totalSupply(), so the swap MUST still succeed.
        evil.setTsRevert(true);

        Rec memory r = _swap(h, key, id, true, -int256(500e18)); // MUST NOT revert
        assertTrue(r.toppedUp, "floor top-up must still fire with totalSupply() reverting");
        // Floor is driven purely by the immutable snapshot; the reverting totalSupply() is irrelevant.
        assertEq(h.floorHigh(), FloorMath.floorPrice(r.reserveBefore + r.project, snap), "floor not snapshot-driven");
        assertGe(h.floorHigh(), floorAtSnapshot, "floor decreased");
        assertEq(r.reserveAfter, r.reserveBefore + r.project - r.topUp, "reserve accounting off");
        _assertSolvent(h, id);
    }

    /* ================================================================== */
    /*  POSITIVE: floorHigh is driven ONLY by the immutable snapshot — both   */
    /*  a mint-after-init and a burn-after-init leave the floor computed off   */
    /*  reserve/snapshot, immune to the LIVE supply. Solvency holds.          */
    /* ================================================================== */

    function test_floorImmuneToPostInitSupply_mintAndBurn() public {
        _mkTokens(4000e18, false);
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);

        uint256 snap = h.backedSupplySnapshot();
        assertEq(snap, 4000e18, "snapshot at bind");

        _seedReserve(key, 800e18);
        // Deep pool: a tiny in-range sell ratchets the floor purely from reserve/snapshot (no subsidy).
        Rec memory s0 = _swap(h, key, id, true, -int256(1e15));
        assertFalse(s0.toppedUp, "deep-pool tiny sell must not top up");
        assertEq(h.floorHigh(), FloorMath.floorPrice(s0.reserveAfter, snap), "floor must equal reserve/snapshot");
        uint256 floorBaseline = h.floorHigh();

        // ---- MINT after init: live supply 4000 -> 104000. The floor must ignore the inflation. ----
        MockERC20(Currency.unwrap(tkn)).mint(address(this), 100_000e18);
        assertEq(MockERC20(Currency.unwrap(tkn)).totalSupply(), 104_000e18, "live supply inflated");
        Rec memory sMint = _swap(h, key, id, true, -int256(1e15));
        assertFalse(sMint.toppedUp, "no subsidy expected");
        assertEq(h.floorHigh(), FloorMath.floorPrice(sMint.reserveAfter, snap), "floor not snapshot-driven after mint");
        assertGe(h.floorHigh(), floorBaseline, "floor decreased after mint");
        _assertSolvent(h, id);

        // ---- BURN after init: live supply 104000 -> 4000 (burn our own bag). Floor must ignore it too. ----
        MockERC20(Currency.unwrap(tkn)).burn(address(this), 100_000e18);
        assertEq(MockERC20(Currency.unwrap(tkn)).totalSupply(), 4_000e18, "live supply back down");
        Rec memory sBurn = _swap(h, key, id, true, -int256(1e15));
        assertFalse(sBurn.toppedUp, "no subsidy expected");
        assertEq(h.floorHigh(), FloorMath.floorPrice(sBurn.reserveAfter, snap), "floor not snapshot-driven after burn");
        assertGe(h.floorHigh(), floorBaseline, "floor decreased after burn");
        _assertSolvent(h, id);
    }
}

/**
 * @notice A fully-compliant ERC-20 (enough surface for v4 settlement) whose `totalSupply()` behaviour is
 *         attacker-controllable: it can REVERT, or attempt to REENTER a target on every read. Used to probe
 *         the reentrancy / DoS boundary of `_backedSupply()`.
 */
contract HostileSupplyToken {
    string public name = "HOSTILE";
    string public symbol = "HST";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 internal _supply;

    bool public tsRevert;
    address public reenterTarget;
    bytes public reenterData;
    bool public reenterOn;
    bool public reentryCallSucceeded;

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
        _supply += v;
    }

    function burn(address from, uint256 v) external {
        balanceOf[from] -= v;
        _supply -= v;
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        return true;
    }

    function transfer(address to, uint256 v) public returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }

    function transferFrom(address f, address to, uint256 v) public returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - v;
        balanceOf[f] -= v;
        balanceOf[to] += v;
        return true;
    }

    function setTsRevert(bool b) external {
        tsRevert = b;
    }

    function armReentry(address t, bytes calldata d, bool on) external {
        reenterTarget = t;
        reenterData = d;
        reenterOn = on;
    }

    /// @dev NON-view on purpose. The hook reads it through `IERC20.totalSupply()` from a `view` function,
    ///      i.e. via STATICCALL — any state-changing reentry here is structurally impossible.
    function totalSupply() external returns (uint256) {
        if (tsRevert) revert("ts-revert");
        if (reenterOn && reenterTarget != address(0)) {
            (bool ok,) = reenterTarget.call(reenterData);
            if (ok) reentryCallSucceeded = true; // will never be reached with a state-changing reentry
        }
        return _supply;
    }
}
