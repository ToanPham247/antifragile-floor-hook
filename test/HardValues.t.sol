// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {AntifragileFloorHook} from "../src/AntifragileFloorHook.sol";

/**
 * @notice Universal hard-value edge cases: zero / 1-wei / near-max amounts, both token orderings, junk
 *         hookData, initialize-twice, wrong-pool binding, non-owner claim, and EIP-170 runtime size.
 */
contract HardValuesTest is Test, Deployers {
    uint160 internal constant FLAGS = 0x10cc;
    address internal constant OWNER = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;
    uint256 internal constant RATE_DENOM = 1_000_000;
    uint24 internal constant FEE = 3000;
    int24 internal constant TS = 60;
    int24 internal constant WIDE_LOWER = -887220;
    int24 internal constant WIDE_UPPER = 887220;

    Currency internal quote;
    Currency internal tkn;

    function setUp() public {
        deployFreshManagerAndRouters();
    }

    function _mk(bool quoteIs0) internal {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (currency0, currency1) = SortTokens.sort(a, b);
        quote = quoteIs0 ? currency0 : currency1;
        tkn = quoteIs0 ? currency1 : currency0;
        MockERC20(Currency.unwrap(currency0)).mint(address(this), 1e30);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 1e30);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
    }

    function _deployHook(uint16 feeBps, Currency q) internal returns (AntifragileFloorHook h) {
        bytes memory args = abi.encode(IPoolManager(address(manager)), feeBps, q);
        (address addr, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(AntifragileFloorHook).creationCode, args);
        h = new AntifragileFloorHook{salt: salt}(IPoolManager(address(manager)), feeBps, q);
        require(address(h) == addr, "mine");
    }

    function _init(AntifragileFloorHook h) internal returns (PoolKey memory key, PoolId id) {
        key = PoolKey(currency0, currency1, FEE, TS, IHooks(address(h)));
        id = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: WIDE_LOWER, tickUpper: WIDE_UPPER, liquidityDelta: int256(1e21), salt: 0}),
            ZERO_BYTES
        );
    }

    function _setup(bool quoteIs0) internal returns (AntifragileFloorHook h, PoolKey memory key, PoolId id) {
        _mk(quoteIs0);
        h = _deployHook(3000, quote);
        (key, id) = _init(h);
    }

    function _claims(AntifragileFloorHook h) internal view returns (uint256) {
        return manager.balanceOf(address(h), quote.toId());
    }

    function _assertSolvent(AntifragileFloorHook h, PoolId id) internal view {
        assertEq(_claims(h), h.reserveQuote() + h.programmableFeeOwed(id, quote), "insolvent");
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amt, bytes memory data) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amt,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            data
        );
    }

    /* ================================================================== */
    /*  zero-amount swap reverts; hook state untouched (both orderings)     */
    /* ================================================================== */

    function test_zeroAmountSwap_reverts_quote0() public {
        _zeroAmount(true);
    }

    function test_zeroAmountSwap_reverts_quote1() public {
        _zeroAmount(false);
    }

    function _zeroAmount(bool quoteIs0) internal {
        (AntifragileFloorHook h, PoolKey memory key, PoolId id) = _setup(quoteIs0);
        uint256 claimsBefore = _claims(h);
        vm.expectRevert(); // v4 core: SwapAmountCannotBeZero
        _swap(key, true, 0, ZERO_BYTES);
        assertEq(_claims(h), claimsBefore, "zero swap must not accrue");
        _assertSolvent(h, id);
    }

    /* ================================================================== */
    /*  1-wei swap executes; fee ceils; no corruption (both orderings)     */
    /* ================================================================== */

    function test_oneWeiSwap_quote0() public {
        _oneWei(true);
    }

    function test_oneWeiSwap_quote1() public {
        _oneWei(false);
    }

    function _oneWei(bool quoteIs0) internal {
        (AntifragileFloorHook h, PoolKey memory key, PoolId id) = _setup(quoteIs0);
        // before-quadrant sell of 1 wei of the quote (exact-output on the quote side keeps gross = 1 wei):
        // simplest: an exact-input swap of 1 wei on the quote-specified side.
        // Use a quote-specified swap so gross is exactly 1 and the fee ceils to 1 wei.
        bool zeroForOne = (quote == currency0); // buy: quote in, quote is specified (exact-input)
        _swap(key, zeroForOne, -int256(1), ZERO_BYTES);
        // fee on gross=1 with 30% effective ceils to 1 wei total; platform ceils to 1 wei.
        uint256 total = _claims(h);
        assertEq(total, _ceilDiv(1 * h.effectiveRate(), RATE_DENOM), "1-wei fee not ceil-correct");
        assertGt(total, 0, "1-wei swap should still charge a ceil fee");
        _assertSolvent(h, id);
    }

    /* ================================================================== */
    /*  near-max amount: graceful (revert or partial), hook not corrupted   */
    /* ================================================================== */

    function test_nearMaxAmount_noCorruption_quote0() public {
        _nearMax(true);
    }

    function test_nearMaxAmount_noCorruption_quote1() public {
        _nearMax(false);
    }

    function _nearMax(bool quoteIs0) internal {
        (AntifragileFloorHook h, PoolKey memory key, PoolId id) = _setup(quoteIs0);
        uint256 floorBefore = h.floorHigh();
        // Absurd exact-output request; core math must revert or partial-fill — never corrupt hook state.
        try this.extSwap(key, true, int256(uint256(type(uint128).max)), ZERO_BYTES) {
            // if it somehow succeeded (bounded by price limit), the hook must still be consistent
        } catch {
            // graceful revert is the expected outcome
        }
        assertGe(h.floorHigh(), floorBefore, "floor decreased on near-max");
        _assertSolvent(h, id);

        // an exact-INPUT near-int128 also must not corrupt state
        try this.extSwap(key, false, -int256(type(int128).max), ZERO_BYTES) {} catch {}
        assertGe(h.floorHigh(), floorBefore, "floor decreased on near-max exact-in");
        _assertSolvent(h, id);
    }

    /// @dev external wrapper so `try/catch` can trap core reverts without aborting the test.
    function extSwap(PoolKey memory key, bool zeroForOne, int256 amt, bytes memory data) external returns (BalanceDelta) {
        require(msg.sender == address(this), "self");
        return _swap(key, zeroForOne, amt, data);
    }

    /* ================================================================== */
    /*  junk hookData must not break the hook (both orderings)              */
    /* ================================================================== */

    function test_junkHookData_ignored_quote0() public {
        _junk(true);
    }

    function test_junkHookData_ignored_quote1() public {
        _junk(false);
    }

    function _junk(bool quoteIs0) internal {
        (AntifragileFloorHook h, PoolKey memory key, PoolId id) = _setup(quoteIs0);
        bytes memory junk = abi.encodePacked(keccak256("junk"), uint256(123), address(this), "garbage-bytes");
        _swap(key, true, -int256(1e18), junk);
        assertGt(_claims(h), 0, "swap with junk hookData should still accrue fee");
        _assertSolvent(h, id);
    }

    /* ================================================================== */
    /*  initialize-twice => PoolAlreadyBound (second pool on same hook)     */
    /* ================================================================== */

    function test_initializeTwice_reverts() public {
        (AntifragileFloorHook h,,) = _setup(true); // binds pool #1 (fee=3000, ts=60)
        // A second pool over the SAME (quote-containing) currencies but different fee => different poolId.
        // v4 wraps the hook's revert in CustomRevert.WrappedError, so we match the embedded inner selector.
        PoolKey memory key2 = PoolKey(currency0, currency1, 500, 10, IHooks(address(h)));
        try manager.initialize(key2, SQRT_PRICE_1_1) {
            revert("initialize-twice should have reverted");
        } catch (bytes memory err) {
            assertTrue(_find4(err, AntifragileFloorHook.PoolAlreadyBound.selector), "inner error != PoolAlreadyBound");
        }
    }

    /* ================================================================== */
    /*  wrong PoolKey (no quote currency) => NotQuotePool                   */
    /* ================================================================== */

    function test_wrongPool_notQuotePool_reverts() public {
        _mk(true); // sets currency0/1; quote = currency0
        AntifragileFloorHook h = _deployHook(3000, quote);

        // Build a pool of two OTHER tokens (neither is `quote`) bound to the same hook.
        MockERC20 x = new MockERC20("X", "X", 18);
        MockERC20 y = new MockERC20("Y", "Y", 18);
        (Currency c0, Currency c1) = SortTokens.sort(x, y);
        PoolKey memory badKey = PoolKey(c0, c1, FEE, TS, IHooks(address(h)));
        try manager.initialize(badKey, SQRT_PRICE_1_1) {
            revert("non-quote pool should have reverted");
        } catch (bytes memory err) {
            assertTrue(_find4(err, AntifragileFloorHook.NotQuotePool.selector), "inner error != NotQuotePool");
        }
    }

    /// @dev Scan revert returndata for a 4-byte selector (v4 embeds hook errors inside CustomRevert.WrappedError).
    function _find4(bytes memory hay, bytes4 needle) internal pure returns (bool) {
        if (hay.length < 4) return false;
        for (uint256 i = 0; i + 4 <= hay.length; i++) {
            if (
                hay[i] == needle[0] && hay[i + 1] == needle[1] && hay[i + 2] == needle[2]
                    && hay[i + 3] == needle[3]
            ) return true;
        }
        return false;
    }

    /* ================================================================== */
    /*  non-owner claim => NotOwner (both orderings)                        */
    /* ================================================================== */

    function test_nonOwnerClaim_reverts_quote0() public {
        _nonOwnerClaim(true);
    }

    function test_nonOwnerClaim_reverts_quote1() public {
        _nonOwnerClaim(false);
    }

    function _nonOwnerClaim(bool quoteIs0) internal {
        (AntifragileFloorHook h, PoolKey memory key, PoolId id) = _setup(quoteIs0);
        _swap(key, quote == currency0, -int256(1e18), ZERO_BYTES); // accrue some liability
        uint256 owed = h.programmableFeeOwed(id, quote);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(AntifragileFloorHook.NotOwner.selector);
        h.claimProgrammableFee(id, quote, makeAddr("stranger"));
        assertEq(h.programmableFeeOwed(id, quote), owed, "liability changed by failed claim");
    }

    /* ================================================================== */
    /*  cross-pool claim on a hook bound elsewhere: liability stays 0       */
    /* ================================================================== */

    function test_ownerClaim_unknownPool_isNoop() public {
        (AntifragileFloorHook h, , PoolId id) = _setup(true);
        // Owner claims against a poolId the hook never accrued for: amount 0, no revert, no payout.
        PoolId bogus = PoolId.wrap(keccak256("bogus"));
        address dest = makeAddr("dest");
        uint256 balBefore = MockERC20(Currency.unwrap(quote)).balanceOf(dest);
        vm.prank(OWNER);
        h.claimProgrammableFee(bogus, quote, dest);
        assertEq(MockERC20(Currency.unwrap(quote)).balanceOf(dest), balBefore, "unknown-pool claim paid out");
        _assertSolvent(h, id);
    }

    /* ================================================================== */
    /*  EIP-170 runtime size + initcode size readout                       */
    /* ================================================================== */

    function test_runtimeBytecodeUnderEip170_andInitcodeSize() public {
        (AntifragileFloorHook h,,) = _setup(true);
        uint256 runtimeSize = address(h).code.length;
        uint256 initcodeSize = type(AntifragileFloorHook).creationCode.length;
        emit log_named_uint("runtime bytecode size", runtimeSize);
        emit log_named_uint("initcode size", initcodeSize);
        assertLt(runtimeSize, 24576, "runtime exceeds EIP-170 limit");
        assertGt(runtimeSize, 0, "no runtime code");
    }
}
