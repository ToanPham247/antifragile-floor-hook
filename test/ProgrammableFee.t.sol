// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {AntifragileFloorHook} from "../src/AntifragileFloorHook.sol";

/**
 * @notice Evidence suite for the mandatory Programmable volume-fee (`programmable-volume-fee-v1`).
 *         Every policy point is exercised against a real v4 PoolManager + funded pool.
 */
contract ProgrammableFeeTest is Test, Deployers {
    uint160 internal constant FLAGS = 0x10cc;
    address internal constant OWNER = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;
    uint256 internal constant PLATFORM_RATE = 1000; // hundredths-of-bip = 10 bps
    uint256 internal constant RATE_DENOM = 1_000_000;

    // wide, deep liquidity so ordinary swaps fully execute (executed == requested)
    int24 internal constant WIDE_LOWER = -887220; // divisible by tickSpacing 60, within [minTick,maxTick]
    int24 internal constant WIDE_UPPER = 887220;
    uint24 internal constant FEE = 3000;
    int24 internal constant TS = 60;

    // events mirrored for expectEmit
    event ProgrammableFeeCollected(
        PoolId indexed poolId, Currency indexed currency, uint256 platformAmount, uint256 projectAmount
    );
    event ProgrammableFeeClaimed(
        PoolId indexed poolId, Currency indexed currency, address indexed destination, uint256 amount
    );

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies(); // sets currency0, currency1 (sorted, ERC20)
    }

    /* ------------------------------------------------------------------ */
    /*                             Harness                                */
    /* ------------------------------------------------------------------ */

    function _deployHook(uint16 feeTotalBps, Currency quote) internal returns (AntifragileFloorHook h) {
        // Precommit the non-quote currency as the expected launch token, plus the canonical 1:1 price + TS,
        // matching the pool {_initPool} binds.
        address expectedToken = Currency.unwrap(quote == currency0 ? currency1 : currency0);
        bytes memory args =
            abi.encode(IPoolManager(address(manager)), feeTotalBps, quote, expectedToken, SQRT_PRICE_1_1, TS);
        (address addr, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(AntifragileFloorHook).creationCode, args);
        h = new AntifragileFloorHook{salt: salt}(
            IPoolManager(address(manager)), feeTotalBps, quote, expectedToken, SQRT_PRICE_1_1, TS
        );
        require(address(h) == addr, "mine");
    }

    function _initPool(AntifragileFloorHook h) internal returns (PoolKey memory key, PoolId id) {
        key = PoolKey(currency0, currency1, FEE, TS, IHooks(address(h)));
        id = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: WIDE_LOWER, tickUpper: WIDE_UPPER, liquidityDelta: int256(1e21), salt: 0}),
            ZERO_BYTES
        );
    }

    function _hookAndPool(uint16 feeTotalBps, Currency quote)
        internal
        returns (AntifragileFloorHook h, PoolKey memory key, PoolId id)
    {
        h = _deployHook(feeTotalBps, quote);
        (key, id) = _initPool(h);
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    function _fee(uint256 gross, uint256 eff)
        internal
        pure
        returns (uint256 total, uint256 platform, uint256 project)
    {
        total = _ceilDiv(gross * eff, RATE_DENOM);
        platform = _ceilDiv(gross * PLATFORM_RATE, RATE_DENOM);
        project = total - platform;
    }

    function _quoteBal(AntifragileFloorHook h, Currency quote) internal view returns (uint256) {
        return manager.balanceOf(address(h), quote.toId());
    }

    /// @dev collect BEFORE iff the quote currency is the swap's specified currency (else AFTER).
    function _quoteIsSpecified(Currency quote, bool zeroForOne, int256 amtSpec) internal view returns (bool) {
        bool specifiedTokenIs0 = ((amtSpec < 0) == zeroForOne);
        return (quote == currency0) == specifiedTokenIs0;
    }

    /// @dev Snapshots, swaps, and returns the accrued split plus the net quote delta seen by the swapper.
    function _swapAndMeasure(
        AntifragileFloorHook h,
        PoolKey memory key,
        PoolId id,
        Currency quote,
        bool zeroForOne,
        int256 amtSpec
    ) internal returns (uint256 total, uint256 platform, uint256 project, int128 qd) {
        uint256 balBefore = _quoteBal(h, quote);
        uint256 owedBefore = h.programmableFeeOwed(id, quote);
        uint256 resBefore = h.reserveQuote();

        BalanceDelta d = swap(key, zeroForOne, amtSpec, ZERO_BYTES);

        total = _quoteBal(h, quote) - balBefore;
        platform = h.programmableFeeOwed(id, quote) - owedBefore;
        project = h.reserveQuote() - resBefore;
        qd = (quote == currency0) ? d.amount0() : d.amount1();
    }

    struct Split {
        uint256 total;
        uint256 platform;
        uint256 project;
        uint256 gross;
    }

    /// @dev Runs one swap on `h`'s pool and asserts the fee split for the quadrant.
    function _checkSwap(
        AntifragileFloorHook h,
        PoolKey memory key,
        PoolId id,
        Currency quote,
        bool zeroForOne,
        int256 amtSpec
    ) internal returns (uint256 total, uint256 platform, uint256 project, uint256 gross) {
        Split memory s;
        int128 qd;
        (s.total, s.platform, s.project, qd) = _swapAndMeasure(h, key, id, quote, zeroForOne, amtSpec);

        // exactness / solvency: the single ERC-6909 claim delta equals the recorded split
        assertEq(s.total, s.platform + s.project, "total != platform + project");

        if (_quoteIsSpecified(quote, zeroForOne, amtSpec)) {
            // before-quadrant: gross is the pre-swap specified amount
            s.gross = amtSpec < 0 ? uint256(-amtSpec) : uint256(amtSpec);
            // exact-output before-quadrant: swapper still receives exactly the requested quote
            if (amtSpec > 0) assertEq(int256(qd), amtSpec, "exactOut quote not honored");
        } else {
            // after-quadrant: gross is the ACTUAL executed quote amount, reconstructed from the delta
            uint256 absQd = qd < 0 ? uint256(int256(-qd)) : uint256(int256(qd));
            s.gross = amtSpec < 0 ? absQd + s.total : absQd - s.total; // in: fee off output; out: fee on input
        }

        _assertFee(h, id, quote, s);
        return (s.total, s.platform, s.project, s.gross);
    }

    function _assertFee(AntifragileFloorHook h, PoolId id, Currency quote, Split memory s) internal {
        uint256 eff = h.effectiveRate();
        assertEq(s.total, _ceilDiv(s.gross * eff, RATE_DENOM), "total mismatch");
        assertEq(s.platform, _ceilDiv(s.gross * PLATFORM_RATE, RATE_DENOM), "platform != 10bps of gross");
        assertEq(s.project, s.total - s.platform, "project split");
        // fees only ever accrue in the quote currency, never the token side
        assertEq(_quoteBal(h, tknOf(quote)), 0, "token-side ERC6909 must stay 0");
        assertEq(h.programmableFeeOwed(id, tknOf(quote)), 0, "token-side liability must stay 0");
    }

    function tknOf(Currency quote) internal view returns (Currency) {
        return quote == currency0 ? currency1 : currency0;
    }

    /* ================================================================== */
    /*  #1  rate levels: 0, <10bps, exactly 10bps, >10bps                 */
    /* ================================================================== */

    function test_01_rateLevels_platformAlways10bps() public {
        uint16[4] memory levels = [uint16(0), uint16(5), uint16(10), uint16(300)];
        for (uint256 i = 0; i < levels.length; i++) {
            (AntifragileFloorHook h, PoolKey memory key, PoolId id) = _hookAndPool(levels[i], currency0);
            // oneForZero exactIn, quote=currency0 -> after-quadrant
            (uint256 total, uint256 platform, uint256 project, uint256 gross) =
                _checkSwap(h, key, id, currency0, false, -1e18);

            // platform is exactly 10 bps of gross, always > 0
            assertEq(platform, _ceilDiv(gross * 1000, RATE_DENOM), "platform != 10bps");
            assertGt(platform, 0, "platform must be > 0");

            if (levels[i] <= 10) {
                // selected <= 10 bps => effective floored to 10 bps => project == 0, total == platform
                assertEq(project, 0, "project should be 0 at/below 10bps floor");
                assertEq(total, platform, "total should equal platform at floor");
            } else {
                // >10bps => project == effective-1000 of gross > 0
                assertGt(project, 0, "project must be > 0 above floor");
                assertEq(project, total - platform, "project split");
            }
        }
    }

    /* ================================================================== */
    /*  #2  non-additive 3% -> 0.1% + 2.9% (feeTotalBps = 300)            */
    /* ================================================================== */

    function test_02_nonAdditive_3pct() public {
        // quote = currency1, zeroForOne exactOut -> before-quadrant, gross = |amtSpec| = 1e18 exactly
        (AntifragileFloorHook h, PoolKey memory key, PoolId id) = _hookAndPool(300, currency1);
        (uint256 total, uint256 platform, uint256 project,) = _checkSwap(h, key, id, currency1, true, int256(1e18));

        // 3% total on 1e18 = 3e16 ; platform 0.1% = 1e15 ; project 2.9% = 2.9e16
        assertEq(platform, 1e15, "platform != 0.1%");
        assertEq(project, 29e15, "project != 2.9%");
        assertEq(total, 3e16, "total != 3.0% (must NOT be 3.1%)");
        assertEq(platform + project, total, "non-additive: split must sum to total");
    }

    /* ================================================================== */
    /*  #3  all 4 quadrants, quote=currency0 AND quote=currency1          */
    /* ================================================================== */

    function test_03_quadrants_quote0() public {
        (AntifragileFloorHook h, PoolKey memory key, PoolId id) = _hookAndPool(300, currency0);
        _checkSwap(h, key, id, currency0, true, -1e18); //  zeroForOne exactIn  -> before
        _checkSwap(h, key, id, currency0, true, int256(1e18)); //  zeroForOne exactOut -> after
        _checkSwap(h, key, id, currency0, false, -1e18); //  oneForZero exactIn  -> after
        _checkSwap(h, key, id, currency0, false, int256(1e18)); //  oneForZero exactOut -> before
    }

    function test_03_quadrants_quote1() public {
        (AntifragileFloorHook h, PoolKey memory key, PoolId id) = _hookAndPool(300, currency1);
        _checkSwap(h, key, id, currency1, true, -1e18); //  zeroForOne exactIn  -> after
        _checkSwap(h, key, id, currency1, true, int256(1e18)); //  zeroForOne exactOut -> before
        _checkSwap(h, key, id, currency1, false, -1e18); //  oneForZero exactIn  -> before
        _checkSwap(h, key, id, currency1, false, int256(1e18)); //  oneForZero exactOut -> after
    }

    /* ================================================================== */
    /*  #4  basis = ACTUAL executed volume (capped / partial fill)        */
    /* ================================================================== */

    function test_04_basisIsExecutedNotRequested() public {
        // quote=currency0, zeroForOne exactOut (after-quadrant, quote is the c0 input, unspecified).
        (AntifragileFloorHook h, PoolKey memory key, PoolId id) = _hookAndPool(300, currency0);

        uint256 requestedOut = 1e24; // absurdly large; will be capped by the price limit
        uint160 limit = uint160((uint256(SQRT_PRICE_1_1) * 999) / 1000); // 0.1% below spot => partial fill

        uint256 balBefore = _quoteBal(h, currency0);
        BalanceDelta d = swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: int256(requestedOut), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        uint256 total = _quoteBal(h, currency0) - balBefore;

        // executed output is strictly less than requested (partial fill)
        assertLt(uint256(int256(d.amount1())), requestedOut, "swap should be capped (executed < requested)");
        assertGt(uint256(int256(d.amount1())), 0, "swap must move something");

        // gross = ACTUAL executed quote input = |net c0 paid| - total (fee added on top for exactOut)
        uint256 gross = uint256(int256(-d.amount0())) - total;

        // fee is measured on the EXECUTED gross, not the requested amount
        assertEq(total, _ceilDiv(gross * h.effectiveRate(), RATE_DENOM), "fee not on executed gross");
        assertEq(h.programmableFeeOwed(id, currency0), _ceilDiv(gross * PLATFORM_RATE, RATE_DENOM), "platform on executed");
        assertEq(h.reserveQuote(), total - h.programmableFeeOwed(id, currency0), "project on executed");
        // sanity: charging on the REQUESTED amount would be vastly larger
        assertTrue(total < _ceilDiv(requestedOut * h.effectiveRate(), RATE_DENOM), "must not charge on requested");
    }

    /* ================================================================== */
    /*  #5  LP fee / plain transfer / alternative pool do NOT accrue      */
    /* ================================================================== */

    function test_05_onlyCanonicalPoolAccrues() public {
        (AntifragileFloorHook h, PoolKey memory key, PoolId id) = _hookAndPool(300, currency0);

        // (a) a plain ERC20 transfer does not touch the hook liability
        IERC20(Currency.unwrap(currency0)).transfer(makeAddr("bob"), 1e18);
        assertEq(_quoteBal(h, currency0), 0, "transfer must not accrue");
        assertEq(h.programmableFeeOwed(id, currency0), 0, "transfer must not accrue liability");

        // (b) an alternative HOOKLESS pool over the same tokens does not accrue to our hook
        PoolKey memory altKey = PoolKey(currency0, currency1, 500, 10, IHooks(address(0)));
        manager.initialize(altKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            altKey,
            ModifyLiquidityParams({tickLower: WIDE_LOWER, tickUpper: WIDE_UPPER, liquidityDelta: int256(1e21), salt: 0}),
            ZERO_BYTES
        );
        swap(altKey, true, -1e18, ZERO_BYTES);
        assertEq(_quoteBal(h, currency0), 0, "alt pool must not accrue");
        assertEq(h.programmableFeeOwed(id, currency0), 0, "alt pool must not accrue liability");

        // (c) the canonical pool DOES accrue (contrast)
        (uint256 total,,,) = _checkSwap(h, key, id, currency0, true, -1e18);
        assertGt(total, 0, "canonical pool must accrue");
    }

    /* ================================================================== */
    /*  #6  self-call / non-PoolManager driving is forbidden              */
    /* ================================================================== */

    function test_06_hookEntrypointsAreOnlyPoolManager() public {
        AntifragileFloorHook h = _deployHook(300, currency0);
        PoolKey memory key = PoolKey(currency0, currency1, FEE, TS, IHooks(address(h)));
        SwapParams memory p = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

        // Only the PoolManager may drive the hook; nobody can self-invoke collection.
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        h.beforeSwap(address(this), key, p, ZERO_BYTES);

        vm.expectRevert(BaseHook.NotPoolManager.selector);
        h.afterSwap(address(this), key, p, BalanceDelta.wrap(0), ZERO_BYTES);

        // unlockCallback is also PoolManager-gated
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        h.unlockCallback(bytes(""));
    }

    /* ================================================================== */
    /*  #7  only owner claims; owner may direct each claim anywhere        */
    /* ================================================================== */

    function test_07_ownerClaimsToArbitraryDestinations() public {
        (AntifragileFloorHook h, PoolKey memory key, PoolId id) = _hookAndPool(300, currency0);

        // accrue some platform liability
        _checkSwap(h, key, id, currency0, true, -1e18);
        uint256 owed1 = h.programmableFeeOwed(id, currency0);
        assertGt(owed1, 0, "need liability");

        address dest1 = makeAddr("dest1");
        vm.prank(OWNER);
        h.claimProgrammableFee(id, currency0, dest1);

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(dest1), owed1, "dest1 not paid");
        assertEq(h.programmableFeeOwed(id, currency0), 0, "liability not zeroed");

        // accrue again, claim to a DIFFERENT destination
        _checkSwap(h, key, id, currency0, true, -1e18);
        uint256 owed2 = h.programmableFeeOwed(id, currency0);
        assertGt(owed2, 0, "need liability 2");

        address dest2 = makeAddr("dest2");
        vm.prank(OWNER);
        h.claimProgrammableFee(id, currency0, dest2);

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(dest2), owed2, "dest2 not paid");
        assertEq(h.programmableFeeOwed(id, currency0), 0, "liability not zeroed 2");
    }

    /* ================================================================== */
    /*  #8  builder/project/random cannot claim or mutate                 */
    /* ================================================================== */

    function test_08_nonOwnerCannotClaim() public {
        (AntifragileFloorHook h, PoolKey memory key, PoolId id) = _hookAndPool(300, currency0);
        _checkSwap(h, key, id, currency0, true, -1e18);

        address[3] memory strangers =
            [makeAddr("builder"), makeAddr("project"), makeAddr("random")];
        for (uint256 i = 0; i < strangers.length; i++) {
            vm.prank(strangers[i]);
            vm.expectRevert(AntifragileFloorHook.NotOwner.selector);
            h.claimProgrammableFee(id, currency0, strangers[i]);
        }
        // liability untouched by the failed attempts
        assertGt(h.programmableFeeOwed(id, currency0), 0, "liability tampered");
    }

    /* ================================================================== */
    /*  #9  no stored mutable recipient; only owner redirects (per claim)  */
    /* ================================================================== */

    function test_09_noStoredRecipient_ownerOnlyRedirect() public {
        (AntifragileFloorHook h, PoolKey memory key, PoolId id) = _hookAndPool(300, currency0);
        _checkSwap(h, key, id, currency0, true, -1e18);
        uint256 owed = h.programmableFeeOwed(id, currency0);

        // a would-be rescuer redirecting to themselves is rejected
        address rescuer = makeAddr("rescuer");
        vm.prank(rescuer);
        vm.expectRevert(AntifragileFloorHook.NotOwner.selector);
        h.claimProgrammableFee(id, currency0, rescuer);

        // only the owner may redirect, and to a fresh arbitrary address each time (no persisted recipient)
        address fresh = makeAddr("freshRecipient");
        vm.prank(OWNER);
        h.claimProgrammableFee(id, currency0, fresh);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(fresh), owed, "owner redirect failed");

        // zero destination is rejected even for the owner
        vm.prank(OWNER);
        vm.expectRevert(AntifragileFloorHook.InvalidDestination.selector);
        h.claimProgrammableFee(id, currency0, address(0));
    }

    /* ================================================================== */
    /*  #10 solvency, pool/currency scoped, no cross-pool netting          */
    /* ================================================================== */

    function test_10_solvencyAndNoCrossPoolNetting() public {
        (AntifragileFloorHook hA, PoolKey memory keyA, PoolId idA) = _hookAndPool(300, currency0);
        (AntifragileFloorHook hB, PoolKey memory keyB, PoolId idB) = _hookAndPool(500, currency1);

        // accrue on both pools
        _checkSwap(hA, keyA, idA, currency0, true, -1e18);
        _checkSwap(hB, keyB, idB, currency1, true, int256(1e18)); // before-quadrant for quote1

        // solvency: each hook's quote ERC-6909 balance == owed platform + project reserve
        assertEq(_quoteBal(hA, currency0), hA.programmableFeeOwed(idA, currency0) + hA.reserveQuote(), "A insolvent");
        assertEq(_quoteBal(hB, currency1), hB.programmableFeeOwed(idB, currency1) + hB.reserveQuote(), "B insolvent");

        // no cross-pool netting: A's liability under B's poolId (or B's currency) is zero, and vice versa
        assertEq(hA.programmableFeeOwed(idB, currency0), 0, "A netted into B poolId");
        assertEq(hA.programmableFeeOwed(idA, currency1), 0, "A netted across currency");
        assertEq(hB.programmableFeeOwed(idA, currency1), 0, "B netted into A poolId");

        // claiming on A must not touch B at all
        uint256 bBalBefore = _quoteBal(hB, currency1);
        uint256 bOwedBefore = hB.programmableFeeOwed(idB, currency1);
        uint256 bResBefore = hB.reserveQuote();
        vm.prank(OWNER);
        hA.claimProgrammableFee(idA, currency0, makeAddr("dA"));
        assertEq(_quoteBal(hB, currency1), bBalBefore, "B balance moved by A claim");
        assertEq(hB.programmableFeeOwed(idB, currency1), bOwedBefore, "B owed moved by A claim");
        assertEq(hB.reserveQuote(), bResBefore, "B reserve moved by A claim");

        // still solvent after the claim
        assertEq(_quoteBal(hA, currency0), hA.programmableFeeOwed(idA, currency0) + hA.reserveQuote(), "A insolvent post-claim");
    }

    /* ================================================================== */
    /*  #11 collection + claim events reconcile with balances             */
    /* ================================================================== */

    function test_11_eventsReconcile() public {
        // quote=currency1, zeroForOne exactOut -> before-quadrant, gross = 1e18 exactly
        (AntifragileFloorHook h, PoolKey memory key, PoolId id) = _hookAndPool(300, currency1);
        (uint256 total, uint256 platform, uint256 project) = (3e16, 1e15, 29e15);

        vm.expectEmit(true, true, false, true, address(h));
        emit ProgrammableFeeCollected(id, currency1, platform, project);
        _checkSwap(h, key, id, currency1, true, int256(1e18));

        // collected event reconciles exactly with the realized ERC-6909 claim balance
        assertEq(_quoteBal(h, currency1), total, "collected != balance");
        assertEq(h.programmableFeeOwed(id, currency1), platform, "owed != platform");
        assertEq(h.reserveQuote(), project, "reserve != project");

        // claim event reconciles exactly with the payout
        address dest = makeAddr("dest");
        vm.expectEmit(true, true, true, true, address(h));
        emit ProgrammableFeeClaimed(id, currency1, dest, platform);
        vm.prank(OWNER);
        h.claimProgrammableFee(id, currency1, dest);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(dest), platform, "claim payout != owed");
        assertEq(_quoteBal(h, currency1), project, "post-claim balance != reserve");
    }

    /* ================================================================== */
    /*  fuzz: fee split correctness across random feeTotalBps + amounts    */
    /* ================================================================== */

    /// forge-config: default.fuzz.runs = 48
    function testFuzz_feeSplit(uint16 feeTotalBps, uint96 amtRaw) public {
        feeTotalBps = uint16(bound(feeTotalBps, 0, 3000)); // up to 30%
        // realistic swap sizes, well within pool depth (1e21 liquidity) so the exact-output swap
        // (amount + carved fee) always fully executes; larger draws are v4-core-unexecutable, not a fee bug.
        uint256 amt = bound(uint256(amtRaw), 1e12, 1e18);

        // before-quadrant with a deterministic gross: quote=currency1, zeroForOne exactOut
        (AntifragileFloorHook h, PoolKey memory key, PoolId id) = _hookAndPool(feeTotalBps, currency1);

        uint256 balBefore = _quoteBal(h, currency1);
        swap(key, true, int256(amt), ZERO_BYTES);

        uint256 total = _quoteBal(h, currency1) - balBefore;
        uint256 platform = h.programmableFeeOwed(id, currency1);
        uint256 project = h.reserveQuote();

        (uint256 eTotal, uint256 ePlatform, uint256 eProject) = _fee(amt, h.effectiveRate());
        assertEq(total, eTotal, "fuzz total");
        assertEq(platform, ePlatform, "fuzz platform");
        assertEq(project, eProject, "fuzz project");
        assertEq(platform + project, total, "fuzz split sums to total");
        assertEq(_quoteBal(h, currency1), total, "fuzz solvency");
        // platform is exactly the 10 bps slice; project is the remainder
        assertEq(platform, _ceilDiv(amt * 1000, RATE_DENOM), "fuzz platform != 10bps");
    }
}
