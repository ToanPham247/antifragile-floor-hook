// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AuditBase} from "./AuditBase.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {AntifragileFloorHook} from "../../src/AntifragileFloorHook.sol";

/**
 * @title BindingFrontrun
 * @notice AUDIT — Vector 4 (afterInitialize binding lifecycle).
 *
 * `_afterInitialize` binds the hook to the FIRST initialized pool that merely CONTAINS `quoteCurrency`;
 * the other side becomes `tknCurrency`, with no check that it is the intended token, and `_bound` blocks
 * any re-bind. Consequences probed here:
 *
 *   (1) GRIEFING / DoS: anyone can front-run the canonical initialization by binding the hook to a pool
 *       of (quote, ATTACKER_TOKEN). The intended (quote, realToken) pool then reverts `PoolAlreadyBound`,
 *       permanently souring THIS hook address. Severity is LOW: the hook address is CREATE2-mined and
 *       single-use, the attacker extracts nothing (owner + reserve are inert on a junk pair), and the
 *       remedy is to re-mine/redeploy — but a deployer MUST initialize atomically to avoid the grief.
 *
 *   (2) The binding is quote-anchored and one-shot: a non-quote pool can never bind (NotQuotePool), and a
 *       second quote pool can never re-bind (PoolAlreadyBound). No hook can serve two pools.
 */
contract BindingFrontrun is AuditBase {
    function setUp() public {
        _setUpManager();
    }

    /// @dev Scan revert returndata for a 4-byte selector (v4 wraps hook errors in CustomRevert.WrappedError).
    function _find4(bytes memory hay, bytes4 needle) internal pure returns (bool) {
        if (hay.length < 4) return false;
        for (uint256 i = 0; i + 4 <= hay.length; i++) {
            if (hay[i] == needle[0] && hay[i + 1] == needle[1] && hay[i + 2] == needle[2] && hay[i + 3] == needle[3]) {
                return true;
            }
        }
        return false;
    }

    /* ================================================================== */
    /*  A front-runner binds the hook to (quote, ATTACKER_TOKEN); the        */
    /*  intended (quote, realToken) pool is then permanently un-bindable.    */
    /* ================================================================== */

    function test_bindingFrontRun_bindsWrongTkn_thenRealPoolDoSed() public {
        // The project mints a hook committed to a quote asset.
        MockERC20 q = new MockERC20("QUOTE", "Q", 18);
        MockERC20 real = new MockERC20("REAL", "R", 18);
        MockERC20 evil = new MockERC20("EVIL", "E", 18);
        quote = Currency.wrap(address(q));

        AntifragileFloorHook h = _deployHook(3000);
        assertEq(Currency.unwrap(h.tknCurrency()), address(0), "tkn not yet bound");

        // ---- ATTACKER front-runs: initialize (quote, EVIL) with this hook FIRST. ----
        (Currency e0, Currency e1) = SortTokens.sort(q, evil);
        PoolKey memory evilKey = PoolKey(e0, e1, FEE, TS, IHooks(address(h)));
        manager.initialize(evilKey, SQRT_PRICE_1_1);

        // The hook is now bound to the ATTACKER's token, not the real one.
        assertEq(Currency.unwrap(h.tknCurrency()), address(evil), "hook bound to attacker token");
        assertEq(PoolId.unwrap(h.poolId()), PoolId.unwrap(evilKey.toId()), "poolId bound to evil pool");

        // ---- The intended (quote, REAL) pool can no longer bind: DoS. ----
        (Currency r0, Currency r1) = SortTokens.sort(q, real);
        PoolKey memory realKey = PoolKey(r0, r1, FEE, TS, IHooks(address(h)));
        try manager.initialize(realKey, SQRT_PRICE_1_1) {
            revert("real pool should have been blocked by PoolAlreadyBound");
        } catch (bytes memory err) {
            assertTrue(_find4(err, AntifragileFloorHook.PoolAlreadyBound.selector), "inner != PoolAlreadyBound");
        }
    }

    /* ================================================================== */
    /*  Re-bind is impossible even with a DIFFERENT tkn on the same quote.   */
    /* ================================================================== */

    function test_cannotRebindToDifferentTkn() public {
        MockERC20 q = new MockERC20("QUOTE", "Q", 18);
        MockERC20 t1 = new MockERC20("T1", "T1", 18);
        MockERC20 t2 = new MockERC20("T2", "T2", 18);
        quote = Currency.wrap(address(q));
        AntifragileFloorHook h = _deployHook(3000);

        (Currency a0, Currency a1) = SortTokens.sort(q, t1);
        manager.initialize(PoolKey(a0, a1, FEE, TS, IHooks(address(h))), SQRT_PRICE_1_1);
        Currency firstTkn = h.tknCurrency();
        assertEq(Currency.unwrap(firstTkn), address(t1), "first bind");

        (Currency b0, Currency b1) = SortTokens.sort(q, t2);
        try manager.initialize(PoolKey(b0, b1, FEE, TS, IHooks(address(h))), SQRT_PRICE_1_1) {
            revert("re-bind should have reverted");
        } catch (bytes memory err) {
            assertTrue(_find4(err, AntifragileFloorHook.PoolAlreadyBound.selector), "inner != PoolAlreadyBound");
        }
        // binding is immutable after the first pool.
        assertEq(Currency.unwrap(h.tknCurrency()), address(t1), "tkn re-bound");
    }

    /* ================================================================== */
    /*  A pool NOT containing the quote currency can never bind.             */
    /* ================================================================== */

    function test_nonQuotePoolNeverBinds() public {
        MockERC20 q = new MockERC20("QUOTE", "Q", 18);
        MockERC20 x = new MockERC20("X", "X", 18);
        MockERC20 y = new MockERC20("Y", "Y", 18);
        quote = Currency.wrap(address(q));
        AntifragileFloorHook h = _deployHook(3000);

        (Currency c0, Currency c1) = SortTokens.sort(x, y); // neither is quote
        try manager.initialize(PoolKey(c0, c1, FEE, TS, IHooks(address(h))), SQRT_PRICE_1_1) {
            revert("non-quote pool should have reverted");
        } catch (bytes memory err) {
            assertTrue(_find4(err, AntifragileFloorHook.NotQuotePool.selector), "inner != NotQuotePool");
        }
        assertEq(Currency.unwrap(h.tknCurrency()), address(0), "must remain unbound after a rejected init");
    }
}
