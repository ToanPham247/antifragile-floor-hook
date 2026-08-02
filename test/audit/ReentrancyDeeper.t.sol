// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AuditBase} from "./AuditBase.sol";
import {HostileSupplyToken} from "./TokenModel.t.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {AntifragileFloorHook} from "../../src/AntifragileFloorHook.sol";

/**
 * @notice A reentrancy probe: `attack()` tries to reenter the pool with a fresh swap. When invoked from
 *         inside the hook's `totalSupply()` read (a STATICCALL frame), any state change here reverts, so
 *         `attack()` reverts and the caller's low-level `.call` returns `false`.
 */
contract ReentryProbe {
    PoolSwapTest public router;
    PoolKey public key;
    bool public sellZeroForOne;

    function wire(PoolSwapTest _r, PoolKey memory _k, bool _s) external {
        router = _r;
        key = _k;
        sellZeroForOne = _s;
    }

    function attack() external {
        router.swap(
            key,
            SwapParams({
                zeroForOne: sellZeroForOne,
                amountSpecified: -int256(1e15),
                sqrtPriceLimitX96: sellZeroForOne ? 4295128739 + 1 : 1461446703485210103287273052203988822378723970342 - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
    }
}

/**
 * @notice An ERC-20 quote token that, on each `transfer`, records the hook's still-outstanding platform
 *         liability. Used to observe that `claimProgrammableFee` follows checks-effects-interactions: the
 *         liability is ZEROED before the external payout transfer, so a reentrant claim would find nothing.
 */
contract CEIObserverQuote is MockERC20 {
    AntifragileFloorHook public hook;
    PoolId public id;
    bool public armed;
    uint256 public owedSeenDuringPayout;
    bool public observed;

    constructor() MockERC20("CEIQ", "CQ", 18) {}

    function wire(AntifragileFloorHook _h, PoolId _id) external {
        hook = _h;
        id = _id;
    }

    function arm(bool on) external {
        armed = on;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed && address(hook) != address(0)) {
            owedSeenDuringPayout = hook.programmableFeeOwed(id, Currency.wrap(address(this)));
            observed = true;
        }
        return super.transfer(to, amount);
    }
}

/**
 * @title ReentrancyDeeper
 * @notice AUDIT — Vector 3 (delta / accounting under reentry), attacking DIFFERENT entrypoints than the
 *         existing Reentrancy suite (which arms TKN/QUOTE `transfer`/`transferFrom` during settlement):
 *
 *   (1) totalSupply() reentry: `_backedSupply()` is `view`, so the hook reads the TKN supply via
 *       STATICCALL. A malicious TKN that tries to reenter (swap / claim / unlock — all state-changing)
 *       from inside `totalSupply()` is neutralized by the read-only frame; it cannot drain or double-spend.
 *
 *   (2) claim payout CEI: `claimProgrammableFee` zeroes the liability BEFORE the external payout, so a
 *       reentrant claim (even from the owner-chosen destination) can never double-spend.
 */
contract ReentrancyDeeper is AuditBase {
    function setUp() public {
        _setUpManager();
    }

    /* ================================================================== */
    /*  totalSupply() reentry is neutralized by the view/STATICCALL frame.  */
    /* ================================================================== */

    function test_reentrantTotalSupply_cannotDrainOrDoubleSpend() public {
        HostileSupplyToken evil = new HostileSupplyToken();
        MockERC20 good = new MockERC20("GOOD", "GD", 18);
        _useTokens(MockERC20(address(evil)), good, false, 3000e18); // TKN = hostile, QUOTE = good
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);
        _seedReserve(key, 1000e18);

        // Wire a probe that reenters the pool with a fresh swap, and arm totalSupply() to invoke it.
        ReentryProbe probe = new ReentryProbe();
        bool sellZeroForOne = (tkn == currency0);
        probe.wire(swapRouter, key, sellZeroForOne);
        evil.armReentry(address(probe), abi.encodeWithSelector(ReentryProbe.attack.selector), true);

        uint256 reserveBefore = h.reserveQuote();
        uint256 claimsBefore = _quoteBal(h);

        // A normal below-floor sell now triggers totalSupply() -> the armed reentrant swap (which must fail
        // silently under STATICCALL). The outer swap must still not let any reentry drain the reserve.
        _modLiq(key, -(FULL_LIQ - int256(1e18)));
        try this.extSell(h, key, sellZeroForOne, 100e18) {
            // If the outer swap completed, the reentry silently failed and nothing was drained abnormally.
            assertFalse(evil.reentryCallSucceeded(), "reentrant call succeeded from totalSupply()!");
            _assertSolvent(h, id);
        } catch {
            // A revert is equally safe: atomic, nothing changed.
            assertEq(h.reserveQuote(), reserveBefore, "reserve moved by a reverted reentrant swap");
            assertEq(_quoteBal(h), claimsBefore, "claims moved by a reverted reentrant swap");
        }
        _assertSolvent(h, id);
    }

    /// @dev external wrapper so try/catch can trap a possible revert without aborting the test.
    function extSell(AntifragileFloorHook h, PoolKey memory key, bool sellZeroForOne, uint256 amt) external {
        require(msg.sender == address(this), "self");
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: sellZeroForOne, amountSpecified: -int256(amt), sqrtPriceLimitX96: _lim(sellZeroForOne)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        h; // silence
    }

    /* ================================================================== */
    /*  claimProgrammableFee follows CEI: liability zeroed BEFORE payout.    */
    /* ================================================================== */

    function test_claimPayout_isCEI_liabilityZeroedBeforeInteraction() public {
        CEIObserverQuote q = new CEIObserverQuote();
        MockERC20 t = new MockERC20("TKN", "T", 18);
        _useTokens(q, t, true, 3000e18); // quote = the observer token
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);
        q.wire(h, id);

        // Accrue a platform liability (a buy: quote-specified, before-quadrant).
        _seedReserve(key, 1000e18);
        uint256 owed = h.programmableFeeOwed(id, quote);
        assertGt(owed, 0, "need a liability");

        // Claim to a fresh destination; the observer records the outstanding liability DURING the payout xfer.
        q.arm(true);
        address dest = makeAddr("dest");
        vm.prank(OWNER);
        h.claimProgrammableFee(id, quote, dest);

        assertTrue(q.observed(), "payout transfer did not fire");
        assertEq(q.owedSeenDuringPayout(), 0, "CEI violated: liability not zeroed before the external payout");
        assertEq(MockERC20(Currency.unwrap(quote)).balanceOf(dest), owed, "payout mismatch");
        _assertSolvent(h, id);
    }
}
