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

import {AntifragileFloorHook} from "../../src/AntifragileFloorHook.sol";

/* ====================================================================== */
/*                                Handler                                  */
/* ====================================================================== */

/**
 * @notice Bounded, random-action handler for a single deployed hook+pool. Each action is a REAL swap /
 *         claim through the v4 PoolManager. Ghost counters record how many of each action ACTUALLY
 *         executed (coverage proof, not reject-masquerade), and property flags are set the instant a
 *         security property is observed to break inside an action.
 */
contract AntifragileHandler {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    uint160 internal constant MIN_PRICE_LIMIT = 4295128739 + 1;
    uint160 internal constant MAX_PRICE_LIMIT = 1461446703485210103287273052203988822378723970342 - 1;
    address internal constant OWNER = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;

    IPoolManager internal immutable manager;
    PoolSwapTest internal immutable swapRouter;
    AntifragileFloorHook internal immutable hook;
    PoolKey internal key;
    PoolId internal immutable id;
    Currency internal immutable quote;
    Currency internal immutable tkn;
    bool internal immutable sellZeroForOne; // sell = TKN in, QUOTE out

    // ---- ghost coverage counters (successful executions) ----
    uint256 public okSellIn;
    uint256 public okBuyIn;
    uint256 public okSellOut;
    uint256 public okBuyOut;
    uint256 public okClaim;
    uint256 public okStrangerReverted;
    // ---- attempts (for revert visibility at the handler level) ----
    uint256 public attempts;
    // ---- observed top-ups (reserve net-decrease on a sell) ----
    uint256 public topUps;

    // ---- property-violation flags (should stay false forever) ----
    bool public monotonicViolated;
    bool public claimAccountingViolated;
    bool public liabilityTamperViolated;

    constructor(
        IPoolManager _m,
        PoolSwapTest _r,
        AntifragileFloorHook _h,
        PoolKey memory _key,
        Currency _quote,
        Currency _tkn
    ) {
        manager = _m;
        swapRouter = _r;
        hook = _h;
        key = _key;
        id = _key.toId();
        quote = _quote;
        tkn = _tkn;
        sellZeroForOne = (_tkn == _key.currency0);
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }

    function _amt(uint256 raw) internal pure returns (uint256) {
        return _bound(raw, 1e12, 1e18); // realistic, well within pool depth
    }

    function _preCheck() internal view returns (uint256 f0, uint256 res0) {
        f0 = hook.floorHigh();
        res0 = hook.reserveQuote();
    }

    function _postCheck(uint256 f0, uint256 res0, bool isSell) internal {
        if (hook.floorHigh() < f0) monotonicViolated = true; // floor must never decrease
        if (isSell && hook.reserveQuote() < res0) topUps++; // reserve net-decrease => a top-up fired
    }

    function _swap(bool zeroForOne, int256 amtSpec) internal {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amtSpec,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
    }

    /* ---- 4 swap actions: {sell,buy} x {exact-in,exact-out}, full-fill (extreme limits) ---- */

    function swapExactInSell(uint256 raw) external {
        attempts++;
        (uint256 f0, uint256 res0) = _preCheck();
        _swap(sellZeroForOne, -int256(_amt(raw))); // exact TKN input
        _postCheck(f0, res0, true);
        okSellIn++;
    }

    function swapExactInBuy(uint256 raw) external {
        attempts++;
        (uint256 f0, uint256 res0) = _preCheck();
        _swap(!sellZeroForOne, -int256(_amt(raw))); // exact QUOTE input
        _postCheck(f0, res0, false);
        okBuyIn++;
    }

    function swapExactOutSell(uint256 raw) external {
        attempts++;
        (uint256 f0, uint256 res0) = _preCheck();
        _swap(sellZeroForOne, int256(_amt(raw))); // exact QUOTE output
        _postCheck(f0, res0, true);
        okSellOut++;
    }

    function swapExactOutBuy(uint256 raw) external {
        attempts++;
        (uint256 f0, uint256 res0) = _preCheck();
        _swap(!sellZeroForOne, int256(_amt(raw))); // exact TKN output
        _postCheck(f0, res0, false);
        okBuyOut++;
    }

    /* ---- owner claim: paid == pre-claim liability, liability zeroes ---- */

    function ownerClaim(uint256 rawDest) external {
        attempts++;
        (uint256 f0, uint256 res0) = _preCheck();
        address dest = address(uint160(uint256(keccak256(abi.encode("dest", rawDest, okClaim)))));
        if (dest == address(0)) dest = address(0xBEEF);

        uint256 owedBefore = hook.programmableFeeOwed(id, quote);
        uint256 destBefore = MockERC20(Currency.unwrap(quote)).balanceOf(dest);

        vm.prank(OWNER);
        hook.claimProgrammableFee(id, quote, dest);

        // paid amount == pre-claim liability, and the liability is zeroed
        uint256 paid = MockERC20(Currency.unwrap(quote)).balanceOf(dest) - destBefore;
        if (paid != owedBefore || hook.programmableFeeOwed(id, quote) != 0) claimAccountingViolated = true;
        _postCheck(f0, res0, false);
        okClaim++;
    }

    /* ---- a non-owner can NEVER reduce the liability ---- */

    function strangerClaim(uint256 rawWho) external {
        attempts++;
        address who = address(uint160(uint256(keccak256(abi.encode("who", rawWho)))));
        if (who == OWNER) who = address(0xABCD);
        uint256 owedBefore = hook.programmableFeeOwed(id, quote);

        vm.prank(who);
        try hook.claimProgrammableFee(id, quote, who) {
            // if it did NOT revert, it must not have reduced the liability
            if (hook.programmableFeeOwed(id, quote) < owedBefore) liabilityTamperViolated = true;
        } catch {
            okStrangerReverted++;
        }
    }
}

/* ====================================================================== */
/*                          Invariant test suite                          */
/* ====================================================================== */

/**
 * @notice Stateful invariant suite for {AntifragileFloorHook}: 256 runs x depth 30 of bounded random
 *         actions against ONE hook+pool, asserting solvency / monotonic floor / reserve-backing /
 *         claimable-liability / no-stuck-currency after every action.
 *
 *  KEY FINDING (see ReserveDrainExploit.t.sol + report): all five of these "standard" invariants HOLD
 *  even though the hook is drainable via a partial-fill top-up. Solvency != safety — these invariants are
 *  necessary but NOT sufficient; the drain is caught only by a reserve-conservation / top-up-fairness
 *  property (AntifragileDrainInvariant.t.sol).
 */
contract AntifragileInvariants is Test, Deployers {
    address internal constant OWNER = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;
    uint160 internal constant FLAGS = 0x10cc;
    uint24 internal constant FEE = 3000;
    int24 internal constant TS = 60;
    int24 internal constant WIDE_LOWER = -887220;
    int24 internal constant WIDE_UPPER = 887220;

    AntifragileFloorHook internal hook;
    AntifragileHandler internal handler;
    PoolKey internal poolKey;
    PoolId internal id;
    Currency internal quote;
    Currency internal tkn;

    function setUp() public {
        deployFreshManagerAndRouters();

        // Controlled-supply TKN so the floor is active; abundant QUOTE.
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (currency0, currency1) = SortTokens.sort(a, b);
        quote = currency1;
        tkn = currency0;
        MockERC20(Currency.unwrap(tkn)).mint(address(this), 4000e18);
        MockERC20(Currency.unwrap(quote)).mint(address(this), 1e30);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);

        // Deploy hook (30% fee) + init a deep pool. Precommit the exact launch identity of that pool:
        // the non-quote token `tkn`, the canonical 1:1 start price and tick spacing TS.
        address expectedToken = Currency.unwrap(tkn);
        bytes memory args =
            abi.encode(IPoolManager(address(manager)), uint16(3000), quote, expectedToken, SQRT_PRICE_1_1, TS);
        (address addr, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(AntifragileFloorHook).creationCode, args);
        hook = new AntifragileFloorHook{salt: salt}(
            IPoolManager(address(manager)), uint16(3000), quote, expectedToken, SQRT_PRICE_1_1, TS
        );
        require(address(hook) == addr, "mine");
        poolKey = PoolKey(currency0, currency1, FEE, TS, IHooks(address(hook)));
        id = poolKey.toId();
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: WIDE_LOWER, tickUpper: WIDE_UPPER, liquidityDelta: int256(1e21), salt: 0}),
            ZERO_BYTES
        );

        // Seed a reserve (buy = QUOTE in) so floorHigh ratchets > 0 before fuzzing.
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(1000e18), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        assertGt(hook.floorHigh(), 0, "floor not active");

        // Deploy + fund the handler generously; it becomes the sole fuzz target.
        handler = new AntifragileHandler(IPoolManager(address(manager)), swapRouter, hook, poolKey, quote, tkn);
        MockERC20(Currency.unwrap(tkn)).mint(address(handler), 1e24);
        MockERC20(Currency.unwrap(quote)).mint(address(handler), 1e30);
        vm.prank(address(handler));
        MockERC20(Currency.unwrap(tkn)).approve(address(swapRouter), type(uint256).max);
        vm.prank(address(handler));
        MockERC20(Currency.unwrap(quote)).approve(address(swapRouter), type(uint256).max);

        targetContract(address(handler));
    }

    function _hookClaims() internal view returns (uint256) {
        return manager.balanceOf(address(hook), quote.toId());
    }

    /* -------------------------------- invariants -------------------------------- */

    /// @notice Exact solvency: the hook's ERC-6909 quote-claim balance == reserve + owed platform liability.
    function invariant_solvency() public view {
        assertEq(_hookClaims(), hook.reserveQuote() + hook.programmableFeeOwed(id, quote), "solvency broken");
    }

    /// @notice The monotonic floor high-water mark never decreases across any action.
    function invariant_floorMonotonic() public view {
        assertFalse(handler.monotonicViolated(), "floorHigh decreased");
    }

    /// @notice The reserve is always fully backed by claims (top-ups are reserve-capped; reserve never underflows).
    function invariant_neverPaysMoreThanReserve() public view {
        assertGe(_hookClaims(), hook.reserveQuote(), "reserve not fully backed by claims");
    }

    /// @notice Owner claims pay exactly the pre-claim liability and zero it; non-owners can never reduce it.
    function invariant_platformLiabilityClaimable() public view {
        assertFalse(handler.claimAccountingViolated(), "owner claim mis-accounted");
        assertFalse(handler.liabilityTamperViolated(), "non-owner reduced the liability");
    }

    /// @notice The hook holds no unaccounted raw ERC-20 of either pool currency (all deltas close each unlock).
    function invariant_noStuckHookDelta() public view {
        assertEq(MockERC20(Currency.unwrap(quote)).balanceOf(address(hook)), 0, "stuck quote ERC20");
        assertEq(MockERC20(Currency.unwrap(tkn)).balanceOf(address(hook)), 0, "stuck tkn ERC20");
    }

    /// @notice COVERAGE PROOF (per run): the fuzzer actually executed real actions (not a reject-masquerade)
    ///         and never observed a property break inside any of them. Foundry reverts handler state between
    ///         runs, so per-run counters are checked here; the campaign-wide, per-selector call/revert counts
    ///         are printed in the invariant call-summary table (reverts == 0 => every call did real work).
    ///         `test_coverage_allActionsExecutable` additionally proves EACH of the six actions is executable.
    function afterInvariant() public view {
        assertGt(handler.attempts(), 0, "no actions executed this run (reject-masquerade)");
        assertFalse(handler.monotonicViolated(), "floorHigh decreased during run");
        assertFalse(handler.claimAccountingViolated(), "owner claim mis-accounted during run");
        assertFalse(handler.liabilityTamperViolated(), "non-owner reduced liability during run");
    }

    /// @notice Deterministic coverage proof: each of the six handler actions genuinely executes and bumps
    ///         its ghost counter (so the fuzzed campaign above is exercising real code paths, not reverts).
    function test_coverage_allActionsExecutable() public {
        handler.swapExactInSell(1e18);
        handler.swapExactInBuy(1e18);
        handler.swapExactOutSell(1e17);
        handler.swapExactOutBuy(1e17);
        handler.ownerClaim(1);
        handler.strangerClaim(2);

        assertGt(handler.okSellIn(), 0, "exact-in sell not executable");
        assertGt(handler.okBuyIn(), 0, "exact-in buy not executable");
        assertGt(handler.okSellOut(), 0, "exact-out sell not executable");
        assertGt(handler.okBuyOut(), 0, "exact-out buy not executable");
        assertGt(handler.okClaim(), 0, "owner claim not executable");
        assertGt(handler.okStrangerReverted(), 0, "non-owner claim not rejected");
        // Invariants still hold after the deterministic sweep.
        invariant_solvency();
        invariant_neverPaysMoreThanReserve();
    }
}
