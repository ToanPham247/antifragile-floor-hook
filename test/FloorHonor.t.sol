// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {AntifragileFloorHook} from "../src/AntifragileFloorHook.sol";
import {FloorMath} from "../src/lib/FloorMath.sol";

/**
 * @notice Evidence suite for the self-funded, monotonic price FLOOR (Design A — "top-up to floor" in
 *         afterSwap, decoupled from the fee, no custom curve). Every scenario runs against a real v4
 *         PoolManager + funded pool. The floor is only meaningful when `backedSupply` (the TKN's
 *         `totalSupply`) is modest, so these tests deploy tokens with a controlled supply (the stock
 *         Deployers currencies mint 2**255, which makes floorPrice≈0 — see the ProgrammableFee suite,
 *         which is therefore provably unaffected by the top-up).
 */
contract FloorHonorTest is Test, Deployers {
    uint160 internal constant FLAGS = 0x10cc;
    address internal constant OWNER = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;
    uint256 internal constant PLATFORM_RATE = 1000;
    uint256 internal constant RATE_DENOM = 1_000_000;
    uint256 internal constant WAD = 1e18;

    uint24 internal constant FEE = 3000;
    int24 internal constant TS = 60;
    int24 internal constant WIDE_LOWER = -887220;
    int24 internal constant WIDE_UPPER = 887220;
    int256 internal constant FULL_LIQ = int256(1e21);

    Currency internal quote;
    Currency internal tkn;

    // Mirror events (identical signatures => identical topic0 selectors) for log scanning.
    event ProgrammableFeeCollected(
        PoolId indexed poolId, Currency indexed currency, uint256 platformAmount, uint256 projectAmount
    );
    event FloorToppedUp(
        PoolId indexed poolId, address indexed swapper, uint256 tknIn, uint256 topUp, uint256 floorHigh
    );
    event FloorRatcheted(PoolId indexed poolId, uint256 floorHigh);

    function setUp() public {
        deployFreshManagerAndRouters();
    }

    /* ------------------------------------------------------------------ */
    /*                              Harness                                */
    /* ------------------------------------------------------------------ */

    /// @dev Deploy TKN (controlled supply) + QUOTE (abundant), pick which is currency0, approve routers.
    function _mkTokens(uint256 tknSupply, bool quoteIs0) internal {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (currency0, currency1) = SortTokens.sort(a, b);
        quote = quoteIs0 ? currency0 : currency1;
        tkn = quoteIs0 ? currency1 : currency0;
        MockERC20(Currency.unwrap(tkn)).mint(address(this), tknSupply);
        MockERC20(Currency.unwrap(quote)).mint(address(this), 1e30);
        _approve(currency0);
        _approve(currency1);
    }

    function _approve(Currency c) internal {
        MockERC20(Currency.unwrap(c)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c)).approve(address(modifyLiquidityRouter), type(uint256).max);
    }

    function _deployHook(uint16 feeTotalBps) internal returns (AntifragileFloorHook h) {
        bytes memory args = abi.encode(IPoolManager(address(manager)), feeTotalBps, quote);
        (address addr, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(AntifragileFloorHook).creationCode, args);
        h = new AntifragileFloorHook{salt: salt}(IPoolManager(address(manager)), feeTotalBps, quote);
        require(address(h) == addr, "mine");
    }

    function _init(AntifragileFloorHook h) internal returns (PoolKey memory key, PoolId id) {
        key = PoolKey(currency0, currency1, FEE, TS, IHooks(address(h)));
        id = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
        _modLiq(key, FULL_LIQ);
    }

    function _modLiq(PoolKey memory key, int256 dl) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: WIDE_LOWER, tickUpper: WIDE_UPPER, liquidityDelta: dl, salt: 0}),
            ZERO_BYTES
        );
    }

    /// @dev Deterministically seed the reserve via a BEFORE-quadrant exact-input BUY (fee on the full
    ///      specified quote input => reserve += project(quoteIn) exactly, independent of pool depth).
    ///      Buy = quote-in: zeroForOne == (quote is currency0).
    function _seedReserve(PoolKey memory key, uint256 quoteIn) internal {
        bool zeroForOne = (quote == currency0);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(quoteIn), sqrtPriceLimitX96: _lim(zeroForOne)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// @dev Extreme price limit in the swap's direction so exact-input swaps always execute (never revert).
    function _lim(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT;
    }

    struct Rec {
        int128 quoteDelta; // seller/ buyer NET quote-side delta (what the swapper received/paid)
        int128 tknDelta;
        uint256 fee; // total fee accrued this swap (platform + project); 0 if none
        uint256 platform; // platform slice accrued
        uint256 project; // project slice accrued (before any top-up burn)
        uint256 topUp; // top-up burned from reserve; 0 if none
        bool toppedUp; // FloorToppedUp emitted
        uint256 reserveBefore;
        uint256 reserveAfter;
        uint256 owedBefore;
        uint256 owedAfter;
    }

    /// @dev Execute one swap on `h`'s pool while capturing the fee/top-up events + reserve movement.
    function _swap(AntifragileFloorHook h, PoolKey memory key, PoolId id, bool zeroForOne, int256 amtSpec)
        internal
        returns (Rec memory r)
    {
        r.reserveBefore = h.reserveQuote();
        r.owedBefore = h.programmableFeeOwed(id, quote);

        vm.recordLogs();
        BalanceDelta d = swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amtSpec, sqrtPriceLimitX96: _lim(zeroForOne)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == ProgrammableFeeCollected.selector) {
                (r.platform, r.project) = abi.decode(logs[i].data, (uint256, uint256));
                r.fee = r.platform + r.project;
            } else if (logs[i].topics[0] == FloorToppedUp.selector) {
                (, r.topUp,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                r.toppedUp = true;
            }
        }

        r.quoteDelta = (quote == currency0) ? d.amount0() : d.amount1();
        r.tknDelta = (quote == currency0) ? d.amount1() : d.amount0();
        r.reserveAfter = h.reserveQuote();
        r.owedAfter = h.programmableFeeOwed(id, quote);
    }

    function _quoteBal(AntifragileFloorHook h) internal view returns (uint256) {
        return manager.balanceOf(address(h), quote.toId());
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    function _uabs(int128 x) internal pure returns (uint256) {
        return x < 0 ? uint256(int256(-x)) : uint256(int256(x));
    }

    /// @dev The pool's raw executed quote output on a SELL = sellerNet + fee - topUp.
    function _ammQuoteOut(Rec memory r) internal pure returns (uint256) {
        // r.quoteDelta = ammOut - fee + topUp  => ammOut = quoteDelta + fee - topUp
        return uint256(int256(r.quoteDelta)) + r.fee - r.topUp;
    }

    /// @dev Assert the hook is solvent: its quote ERC-6909 balance backs reserve + owed exactly.
    function _assertSolvent(AntifragileFloorHook h, PoolId id) internal view {
        assertEq(_quoteBal(h), h.reserveQuote() + h.programmableFeeOwed(id, quote), "insolvent: bal != reserve+owed");
    }

    /* ================================================================== */
    /*  #1 / #6  sell below floor is topped up (BOTH token orderings)      */
    /* ================================================================== */

    function test_01_sellBelowFloor_toppedUp_quote1() public {
        _runSellBelowFloor(false);
    }

    function test_06_sellBelowFloor_toppedUp_quote0() public {
        _runSellBelowFloor(true);
    }

    function _runSellBelowFloor(bool quoteIs0) internal {
        _mkTokens(3000e18, quoteIs0); // backedSupply = 3000 TKN (1000 used by LP, ~2000 spare)
        AntifragileFloorHook h = _deployHook(3000); // 30% fee
        (PoolKey memory key, PoolId id) = _init(h);

        // Grow reserve so the floor is well above zero.
        _seedReserve(key, 1000e18);
        uint256 floorHigh = h.floorHigh();
        assertGt(floorHigh, 0, "floor not grown");
        // Floor is driven by the immutable snapshot captured at bind time (== live supply for this
        // fixed-supply mock, but read from the snapshot to be explicit about the hardened source).
        assertEq(h.backedSupplySnapshot(), 3000e18, "snapshot must equal the fixed supply at bind");
        assertEq(floorHigh, FloorMath.floorPrice(h.reserveQuote(), h.backedSupplySnapshot()), "floor != reserve/snapshot");

        // Thin the pool so the AMM prices the sell FAR below the floor.
        _modLiq(key, -(FULL_LIQ - int256(1e18)));

        uint256 sellTkn = 1500e18;
        uint256 targetGross = (floorHigh * sellTkn) / WAD;

        bool sellZeroForOne = !quoteIs0; // sell = TKN in, QUOTE out
        Rec memory r = _swap(h, key, id, sellZeroForOne, -int256(sellTkn));

        // top-up happened and was funded from the reserve
        assertTrue(r.toppedUp, "expected top-up");
        assertGt(r.topUp, 0, "topUp must be > 0");
        assertEq(r.reserveAfter, r.reserveBefore + r.project - r.topUp, "reserve accounting");
        assertLt(r.reserveAfter, r.reserveBefore, "reserve must have net-decreased (topUp >> fee)");

        // FLOOR HONORED (full): gross quote-side (sellerNet + fee) reached the target within rounding dust.
        uint256 sellerNet = uint256(int256(r.quoteDelta));
        uint256 gross = sellerNet + r.fee; // == ammOut + topUp
        assertGe(gross, targetGross - 1, "gross below floor target");
        // task assertion: seller receives >= targetGross - fee - 1
        assertGe(sellerNet, targetGross - r.fee - 1, "seller under floor-minus-fee");
        // the AMM alone would have paid FAR less (proves the subsidy did the work)
        assertLt(_ammQuoteOut(r), targetGross / 2, "AMM should have priced well below floor");

        _assertSolvent(h, id);
    }

    /* ================================================================== */
    /*  #2  small sell above floor uses the AMM only (no top-up)           */
    /* ================================================================== */

    function test_02_smallSellAboveFloor_noTopUp() public {
        _mkTokens(3000e18, false); // quote = currency1
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);

        _seedReserve(key, 1000e18); // floor ~0.0997 QUOTE/TKN; the seed buy leaves spot ABOVE the floor
        // keep the pool DEEP (no liquidity removal) so a tiny sell barely moves price

        uint256 tinySell = 1e15; // 0.001 TKN
        uint256 resBefore = h.reserveQuote();
        Rec memory r = _swap(h, key, id, true, -int256(tinySell)); // zeroForOne sell (quote=currency1)

        assertFalse(r.toppedUp, "tiny sell must NOT be topped up");
        assertEq(r.topUp, 0, "no top-up");
        // reserve only GREW by the fee's project slice (no subsidy burn)
        assertEq(r.reserveAfter, resBefore + r.project, "reserve should only grow by fee project");
        assertGe(r.reserveAfter, resBefore, "reserve must not shrink");
        // seller got the plain AMM output net of fee (no subsidy)
        assertEq(uint256(int256(r.quoteDelta)), _ammQuoteOut(r) - r.fee, "seller != ammOut - fee");
        _assertSolvent(h, id);
    }

    /* ================================================================== */
    /*  #3  partial honor when reserve is small vs the (stale-high) target */
    /* ================================================================== */

    function test_03_partialHonor_reserveExhausted() public {
        _mkTokens(3000e18, false); // quote = currency1, initial supply 3000
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);

        _seedReserve(key, 1000e18);
        uint256 floorHigh = h.floorHigh();
        assertGt(floorHigh, 0, "floor not grown");

        // Inflate the TKN supply AFTER ratcheting: current floor drops, but floorHigh holds (monotonic),
        // and we now hold enough TKN to offer more than the originally-backed supply.
        MockERC20(Currency.unwrap(tkn)).mint(address(this), 7000e18); // supply 3000 -> 10000
        assertEq(h.floorHigh(), floorHigh, "floorHigh must not change on mint (yet)");

        _modLiq(key, -(FULL_LIQ - int256(1e18))); // thin the pool so ammOut ~ tiny

        uint256 reserveBefore = h.reserveQuote();
        uint256 sellTkn = 6000e18; // > original supply => target (floorHigh*sellTkn) >> reserve
        uint256 targetGross = (h.floorHigh() * sellTkn) / WAD;
        assertGt(targetGross, reserveBefore, "target must exceed reserve for a partial honor");

        Rec memory r = _swap(h, key, id, true, -int256(sellTkn));

        // ALL remaining reserve was paid out; nothing left; no revert; no insolvency.
        // The top-up drains the whole POST-fee reserve (reserveBefore + this swap's project slice),
        // because the fee's project is added to `reserveQuote` before the top-up caps against it.
        assertTrue(r.toppedUp, "expected partial top-up");
        assertEq(r.topUp, reserveBefore + r.project, "partial honor must drain the WHOLE (post-fee) reserve");
        assertEq(r.reserveAfter, 0, "reserve must be exhausted to 0");
        // seller received ammOut + wholeReserve - fee, strictly BELOW the floor target (partial honor)
        uint256 gross = uint256(int256(r.quoteDelta)) + r.fee; // == ammOut + topUp
        assertEq(gross, _ammQuoteOut(r) + reserveBefore + r.project, "gross != ammOut + wholeReserve");
        assertLt(gross, targetGross, "partial honor: gross must be below target");
        _assertSolvent(h, id);
    }

    /* ================================================================== */
    /*  #4  floorHigh is monotonic across a mixed sequence                 */
    /* ================================================================== */

    function test_04_floorHigh_monotonic() public {
        _mkTokens(3000e18, false);
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);

        uint256 prev = h.floorHigh(); // 0
        uint256[6] memory marks;
        uint256 m;

        _seedReserve(key, 500e18);
        marks[m++] = h.floorHigh();

        _seedReserve(key, 800e18); // grow further
        marks[m++] = h.floorHigh();

        // a small in-range sell (accrues fee, no drain)
        _swap(h, key, id, true, -int256(1e15));
        marks[m++] = h.floorHigh();

        // thin pool + big sell that DRAINS reserve via top-up (reserve falls, floorHigh must hold)
        _modLiq(key, -(FULL_LIQ - int256(1e18)));
        _swap(h, key, id, true, -int256(1500e18));
        marks[m++] = h.floorHigh();

        // inflate supply (current floor drops sharply) — floorHigh must still hold
        MockERC20(Currency.unwrap(tkn)).mint(address(this), 50000e18);
        _swap(h, key, id, true, -int256(1e15));
        marks[m++] = h.floorHigh();

        // a buy (never lowers floorHigh)
        _swap(h, key, id, false, -int256(10e18));
        marks[m++] = h.floorHigh();

        for (uint256 i = 0; i < m; i++) {
            assertGe(marks[i], prev, "floorHigh decreased");
            prev = marks[i];
        }
        assertGt(marks[1], 0, "floor never grew");
        _assertSolvent(h, id);
    }

    /* ================================================================== */
    /*  #5  buys are never topped up (exact-in AND exact-out)              */
    /* ================================================================== */

    function test_05_buysNeverToppedUp() public {
        _mkTokens(3000e18, false); // quote = currency1; buy = oneForZero (zeroForOne=false)
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);

        _seedReserve(key, 1000e18); // floorHigh > 0, reserve > 0 (so a sell WOULD top up)
        assertGt(h.floorHigh(), 0, "floor not grown");
        assertGt(h.reserveQuote(), 0, "reserve empty");

        // exact-input buy (quote in)
        uint256 resBefore = h.reserveQuote();
        Rec memory rIn = _swap(h, key, id, false, -int256(50e18));
        assertFalse(rIn.toppedUp, "exact-in buy topped up");
        assertEq(rIn.topUp, 0, "exact-in buy topUp");
        assertGe(h.reserveQuote(), resBefore, "buy must not drain reserve");

        // exact-output buy (exact TKN out, quote in)
        resBefore = h.reserveQuote();
        Rec memory rOut = _swap(h, key, id, false, int256(20e18));
        assertFalse(rOut.toppedUp, "exact-out buy topped up");
        assertEq(rOut.topUp, 0, "exact-out buy topUp");
        assertGe(h.reserveQuote(), resBefore, "buy must not drain reserve");
        _assertSolvent(h, id);
    }

    /* ================================================================== */
    /*  #7  exact-OUTPUT sell: no top-up, no revert (documented behavior)   */
    /* ================================================================== */

    function test_07_exactOutputSell_noTopUp_noRevert() public {
        _mkTokens(3000e18, false); // quote = currency1; sell = zeroForOne
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);

        _seedReserve(key, 1000e18); // floorHigh > 0, reserve > 0
        assertGt(h.floorHigh(), 0, "floor not grown");

        uint256 resBefore = h.reserveQuote();
        // exact-OUTPUT sell: request exact QUOTE out, pay TKN in (amountSpecified > 0), keep pool deep.
        uint256 wantQuote = 5e18;
        Rec memory r = _swap(h, key, id, true, int256(wantQuote));

        assertFalse(r.toppedUp, "exact-output sell must NOT top up");
        assertEq(r.topUp, 0, "exact-out sell topUp");
        // swapper receives exactly the requested quote out (before-quadrant honors exact output)
        assertEq(uint256(int256(r.quoteDelta)), wantQuote, "exact-out quote not honored");
        assertGe(h.reserveQuote(), resBefore, "reserve must not drain on exact-out sell");
        _assertSolvent(h, id);
    }

    /* ================================================================== */
    /*  #8  solvency invariant under a random swap sequence + a claim      */
    /* ================================================================== */

    /// forge-config: default.fuzz.runs = 24
    function testFuzz_08_solvencyInvariant(uint256 seed) public {
        _mkTokens(4000e18, false);
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);

        _seedReserve(key, 1000e18); // active floor
        // give the tester ample TKN to sell without running dry; raises supply (lowers floor, fine)
        MockERC20(Currency.unwrap(tkn)).mint(address(this), 200000e18);
        _modLiq(key, -(FULL_LIQ / 2)); // leave HALF the liquidity: swaps still execute, sells can bind

        for (uint256 i = 0; i < 8; i++) {
            uint256 x = uint256(keccak256(abi.encode(seed, i)));
            bool zeroForOne = (x & 1) == 0; // true = sell (quote=currency1), false = buy
            // exact-INPUT only, bounded => never reverts on depth (partial-fills at the price limit)
            int256 amt = -int256(bound(uint256(x >> 8), 1e15, 100e18));

            _swap(h, key, id, zeroForOne, amt); // must not revert
            _assertSolvent(h, id); // exact backing after every swap
        }

        // owner claims the platform liability; still solvent afterward
        if (h.programmableFeeOwed(id, quote) > 0) {
            vm.prank(OWNER);
            h.claimProgrammableFee(id, quote, makeAddr("claimDest"));
        }
        _assertSolvent(h, id);
    }

    /* ================================================================== */
    /*  #9  reentrancy / auth: hook entrypoints are onlyPoolManager        */
    /* ================================================================== */

    function test_09_entrypointsAreOnlyPoolManager() public {
        _mkTokens(3000e18, false);
        AntifragileFloorHook h = _deployHook(3000);
        PoolKey memory key = PoolKey(currency0, currency1, FEE, TS, IHooks(address(h)));
        SwapParams memory p = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

        vm.expectRevert(BaseHook.NotPoolManager.selector);
        h.beforeSwap(address(this), key, p, ZERO_BYTES);

        vm.expectRevert(BaseHook.NotPoolManager.selector);
        h.afterSwap(address(this), key, p, BalanceDelta.wrap(0), ZERO_BYTES);

        vm.expectRevert(BaseHook.NotPoolManager.selector);
        h.unlockCallback(bytes(""));
    }

    /* ================================================================== */
    /*  #10  the top-up does NOT change the fee basis (still ammQuoteOut)   */
    /* ================================================================== */

    function test_10_feeBasisUnchangedByTopUp() public {
        _mkTokens(3000e18, false);
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);

        _seedReserve(key, 1000e18);
        _modLiq(key, -(FULL_LIQ - int256(1e18))); // thin => big top-up on the sell

        Rec memory r = _swap(h, key, id, true, -int256(1500e18));
        assertTrue(r.toppedUp, "need a topped-up sell to prove fee basis");

        // Reconstruct the pool's ACTUAL executed quote output and prove the fee was charged on IT
        // (executed swap volume), NOT on the subsidised gross (ammOut + topUp).
        uint256 ammOut = _ammQuoteOut(r);
        uint256 eff = h.effectiveRate();
        assertEq(r.fee, _ceilDiv(ammOut * eff, RATE_DENOM), "fee not on executed ammQuoteOut");
        assertEq(r.platform, _ceilDiv(ammOut * PLATFORM_RATE, RATE_DENOM), "platform not on executed ammQuoteOut");
        assertEq(r.project, r.fee - r.platform, "project split");
        // charging on the subsidised gross would be strictly larger — confirm it is NOT that
        uint256 grossReached = uint256(int256(r.quoteDelta)) + r.fee; // ~= targetGross
        assertLt(r.fee, _ceilDiv(grossReached * eff, RATE_DENOM), "fee must NOT be charged on the subsidised gross");
        _assertSolvent(h, id);
    }
}
