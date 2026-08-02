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

/**
 * @title TokenModelBoundary
 * @notice AUDIT — Vector 1 (floor / reserve economics under a non-standard TKN).
 *
 * The floor price is `reserveQuote * 1e18 / IERC20(tkn).totalSupply()` and `floorHigh` ratchets that
 * value monotonically. A TKN whose `totalSupply()` can MOVE (mintable / burnable-anyone / rebasing) can
 * therefore move — and, because of the ratchet, permanently SPIKE — `floorHigh`. This suite maps the
 * exact boundary:
 *
 *   • FIX BOUND (holds for ALL tokens, standard or hostile): the reserve-funded top-up on any single
 *     sell is <= floorHigh * EXECUTED_tkn / 1e18 (+1 wei ceil). The reserve outflow is always bounded by
 *     the floor-value of the TKN actually delivered — this is the cd2109a fix and it never regresses.
 *
 *   • IN-MODEL (fixed-supply, or ERC20Burnable burn-your-OWN): supply cannot be moved to an attacker's
 *     advantage. Burning your own tokens raises the per-token floor but leaves you fewer tokens to
 *     redeem; net extraction only DROPS (algebra in docs/AUDIT.md). No profitable attack. Solvent.
 *
 *   • OUT-OF-MODEL (admin burn-ANYONE / negative rebase that cuts *other* holders): a fractional holder
 *     can crater `totalSupply` without cutting their own balance, spiking `floorHigh`, then redeem their
 *     unchanged holding against the (now illegitimately high) floor and drain a large slice of the shared
 *     reserve. This breaks the floor VALUE guarantee — but NOT solvency, and NOT the platform liability:
 *     the drain is bounded to `reserveQuote`, the owner's 10bps is never touched. This is the disclosed
 *     token assumption: the hook is solvent against any ERC-20, but the *floor value* is only meaningful
 *     for a fixed / honestly-supplied TKN.
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
    /*  FIX BOUND holds under a supply BURN: top-up <= fair value of the    */
    /*  EXECUTED tkn at the (post-burn, spiked) floor. Reserve outflow is    */
    /*  bounded; solvency holds.                                             */
    /* ================================================================== */

    function test_burnOwnSupply_topUpBoundedByExecutedFairValue() public {
        _mkTokens(10_000e18, false); // quote = currency1; big supply so we hold plenty to burn
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);

        _seedReserve(key, 1000e18);
        uint256 floorBefore = h.floorHigh();
        assertGt(floorBefore, 0, "floor not grown");

        // Thin the pool so a sell prices below the floor (a top-up will fire).
        _modLiq(key, -(FULL_LIQ - int256(1e18)));

        // Burn a big chunk of our OWN holdings -> totalSupply craters -> floorHigh will ratchet UP.
        MockERC20(Currency.unwrap(tkn)).burn(address(this), 7000e18);

        Rec memory r = _swap(h, key, id, true, -int256(500e18));
        uint256 exec = _execTknIn(r);
        uint256 floorNow = h.floorHigh();

        // floorHigh spiked because supply fell.
        assertGt(floorNow, floorBefore, "burn should have ratcheted floorHigh up");

        // THE FIX BOUND: the reserve subsidy never exceeds the floor-value of the EXECUTED tkn (+1 wei).
        uint256 fairAtCurrentFloor = (floorNow * exec) / WAD;
        assertLe(r.topUp, fairAtCurrentFloor + 1, "top-up exceeded fair value of executed tkn @ current floor");

        // Reserve conservation: the ONLY reserve outflow is that bounded top-up.
        assertEq(r.reserveAfter, r.reserveBefore + r.project - r.topUp, "reserve accounting off");
        _assertSolvent(h, id);
    }

    /* ================================================================== */
    /*  OUT-OF-MODEL: admin burn-ANYONE lets a FRACTIONAL holder spike the   */
    /*  floor and over-extract the shared reserve — but solvency + the       */
    /*  platform liability survive intact (drain is bounded to reserveQuote). */
    /* ================================================================== */

    function test_adminBurnAnyone_overExtractsReserve_butSolventAndLiabilityIntact() public {
        // Plain MockERC20: its `burn(from,amount)` is UNAUTHENTICATED (== admin burn-anyone), the exact
        // out-of-model primitive. quote = currency1.
        _mkTokens(5000e18, false);
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);

        _seedReserve(key, 1000e18);
        uint256 floorLegit = h.floorHigh(); // the honest floor before any manipulation
        assertGt(floorLegit, 0, "floor not grown");

        // Thin the pool: models a DUMP where spot has fallen below the floor — the floor's use case.
        _modLiq(key, -(FULL_LIQ - int256(1e18)));

        // Keep a small attacker bag; move the rest of the circulating supply to an innocent "victim",
        // then crater totalSupply by burning the VICTIM's tokens (attacker's own bag untouched).
        uint256 attackerBag;
        {
            address victim = makeAddr("victim");
            uint256 sendToVictim = MockERC20(Currency.unwrap(tkn)).balanceOf(address(this)) - 50e18;
            MockERC20(Currency.unwrap(tkn)).transfer(victim, sendToVictim);
            attackerBag = MockERC20(Currency.unwrap(tkn)).balanceOf(address(this));
            MockERC20(Currency.unwrap(tkn)).burn(victim, MockERC20(Currency.unwrap(tkn)).balanceOf(victim));
        }

        uint256 reserveBefore = h.reserveQuote();
        uint256 owedBefore = h.programmableFeeOwed(id, quote);

        // Attacker redeems their unchanged bag against the now-spiked floor.
        Rec memory r = _swap(h, key, id, true, -int256(attackerBag));
        uint256 exec = _execTknIn(r);
        uint256 floorSpiked = h.floorHigh();

        emit log_named_uint("floorLegit  (honest)      ", floorLegit);
        emit log_named_uint("floorSpiked (post-burn)   ", floorSpiked);
        emit log_named_uint("executed TKN sold         ", exec);
        emit log_named_uint("reserveBefore attack      ", reserveBefore);
        emit log_named_uint("topUp extracted (subsidy) ", r.topUp);
        emit log_named_uint("fair value @ honest floor ", (floorLegit * exec) / WAD);
        emit log_named_uint("reserveAfter attack       ", r.reserveAfter);

        // The floor was spiked well above the honest value by the supply crater.
        assertGt(floorSpiked, floorLegit * 2, "floor should have spiked from the supply crater");
        // OVER-EXTRACTION: the subsidy vastly exceeds what the delivered tkn was worth at the HONEST floor.
        assertGt(r.topUp, ((floorLegit * exec) / WAD) * 3, "attacker should over-extract vs the honest floor value");
        // NET RESERVE DRAIN despite the fee this swap added.
        assertLt(r.reserveAfter, reserveBefore, "reserve should have net-drained");
        // ...but the fix bound STILL holds wrt the (illegitimate) spiked floor — never beyond it.
        assertLe(r.topUp, (floorSpiked * exec) / WAD + 1, "top-up beyond fair value @ spiked floor");

        // SOLVENCY preserved, PLATFORM LIABILITY untouched by the drain, and still fully claimable.
        _assertSolvent(h, id);
        assertEq(h.programmableFeeOwed(id, quote), owedBefore + r.platform, "platform liability corrupted by drain");
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
    /*  Supply INFLATION (mint) cannot drain the reserve; floorHigh is       */
    /*  monotonic and a low current price never forces a top-up on a buy.    */
    /* ================================================================== */

    function test_mintInflateSupply_noDrain_floorMonotonic() public {
        _mkTokens(3000e18, false);
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);

        _seedReserve(key, 1000e18);
        uint256 floorBefore = h.floorHigh();
        uint256 reserveBefore = h.reserveQuote();

        // Inflate supply massively -> current floorPrice collapses, but floorHigh must HOLD (monotonic).
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
    /*  A TKN whose totalSupply() REVERTS bricks swaps (DoS) but never        */
    /*  corrupts hook state — a reverted swap is atomic. (Out-of-model: a     */
    /*  standard ERC-20 totalSupply never reverts.)                          */
    /* ================================================================== */

    function test_revertingTotalSupply_bricksSwaps_noCorruption() public {
        HostileSupplyToken evil = new HostileSupplyToken();
        MockERC20 good = new MockERC20("GOOD", "GD", 18);
        // TKN = hostile, QUOTE = good.
        _useTokens(MockERC20(address(evil)), good, false, 3000e18);
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);

        _seedReserve(key, 500e18);
        uint256 reserveBefore = h.reserveQuote();
        uint256 floorBefore = h.floorHigh();
        uint256 claimsBefore = _quoteBal(h);

        // Arm the revert: totalSupply() now throws -> _backedSupply() reverts -> afterSwap reverts -> swap reverts.
        evil.setTsRevert(true);

        bool sellZeroForOne = (tkn == currency0);
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: sellZeroForOne, amountSpecified: -int256(10e18), sqrtPriceLimitX96: _lim(sellZeroForOne)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // No partial state: the reverted swap changed nothing.
        assertEq(h.reserveQuote(), reserveBefore, "reserve moved by a reverted swap");
        assertEq(h.floorHigh(), floorBefore, "floor moved by a reverted swap");
        assertEq(_quoteBal(h), claimsBefore, "claims moved by a reverted swap");
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
