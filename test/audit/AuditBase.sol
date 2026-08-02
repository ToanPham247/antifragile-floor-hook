// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {AntifragileFloorHook} from "../../src/AntifragileFloorHook.sol";

/**
 * @title AuditBase
 * @notice Shared harness for the internal adversarial security audit. Mirrors the FloorHonor harness
 *         (real v4 PoolManager + funded pool, event-capturing swap, solvency helper) but is generic over
 *         the *token contracts* so tests can plug in hostile ERC-20s (burn-anyone, mintable, rebasing,
 *         reverting-totalSupply, reentrant-totalSupply) to probe the token-model boundary.
 */
abstract contract AuditBase is Test, Deployers {
    using StateLibrary for IPoolManager;

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

    // Mirror events (identical signatures => identical topic0) for log scanning.
    event ProgrammableFeeCollected(
        PoolId indexed poolId, Currency indexed currency, uint256 platformAmount, uint256 projectAmount
    );
    event FloorToppedUp(
        PoolId indexed poolId, address indexed swapper, uint256 tknIn, uint256 topUp, uint256 floorHigh
    );
    event FloorRatcheted(PoolId indexed poolId, uint256 floorHigh);

    function _setUpManager() internal {
        deployFreshManagerAndRouters();
    }

    /* ------------------------------------------------------------------ */
    /*                          Token wiring                              */
    /* ------------------------------------------------------------------ */

    /// @dev Plug two arbitrary ERC-20 contracts into a pool; `quoteIsA` selects which is the quote asset.
    ///      TKN gets `tknSupply` minted to the tester, QUOTE gets an abundant balance. Approvals set.
    function _useTokens(MockERC20 a, MockERC20 b, bool quoteIsA, uint256 tknSupply) internal {
        (currency0, currency1) = SortTokens.sort(a, b);
        MockERC20 quoteC = quoteIsA ? a : b;
        MockERC20 tknC = quoteIsA ? b : a;
        quote = Currency.wrap(address(quoteC));
        tkn = Currency.wrap(address(tknC));
        tknC.mint(address(this), tknSupply);
        quoteC.mint(address(this), 1e30);
        _approve(currency0);
        _approve(currency1);
    }

    /// @dev Convenience: two plain MockERC20s.
    function _mkTokens(uint256 tknSupply, bool quoteIs0) internal {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        // quoteIs0 means quote should end up as currency0; pick after sort by wiring both then choosing.
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

    /* ------------------------------------------------------------------ */
    /*                           Deploy + init                            */
    /* ------------------------------------------------------------------ */

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

    /// @dev Deterministically seed the reserve via a BEFORE-quadrant exact-input BUY.
    function _seedReserve(PoolKey memory key, uint256 quoteIn) internal {
        bool zeroForOne = (quote == currency0);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(quoteIn), sqrtPriceLimitX96: _lim(zeroForOne)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function _lim(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT;
    }

    /* ------------------------------------------------------------------ */
    /*                        Swap + measurement                          */
    /* ------------------------------------------------------------------ */

    struct Rec {
        int128 quoteDelta;
        int128 tknDelta;
        uint256 fee;
        uint256 platform;
        uint256 project;
        uint256 topUp;
        bool toppedUp;
        uint256 reserveBefore;
        uint256 reserveAfter;
        uint256 owedBefore;
        uint256 owedAfter;
    }

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
            if (logs[i].emitter != address(h)) continue;
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

    /// @dev A tight-price-limit exact-input SELL (partial fill possible). Returns executed tkn in + quote out.
    function _tightSell(AntifragileFloorHook, PoolKey memory key, PoolId id, uint256 requestedTkn)
        internal
        returns (uint256 tknGivenUp, uint256 quoteReceived)
    {
        bool sellZeroForOne = (tkn == currency0);
        (uint160 curSqrt,,,) = manager.getSlot0(id);
        uint160 tightLimit = sellZeroForOne ? curSqrt - (curSqrt / 100000) : curSqrt + (curSqrt / 100000);
        uint256 tBefore = MockERC20(Currency.unwrap(tkn)).balanceOf(address(this));
        uint256 qBefore = MockERC20(Currency.unwrap(quote)).balanceOf(address(this));
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: sellZeroForOne, amountSpecified: -int256(requestedTkn), sqrtPriceLimitX96: tightLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        tknGivenUp = tBefore - MockERC20(Currency.unwrap(tkn)).balanceOf(address(this));
        quoteReceived = MockERC20(Currency.unwrap(quote)).balanceOf(address(this)) - qBefore;
    }

    /* ------------------------------------------------------------------ */
    /*                            Assertions                              */
    /* ------------------------------------------------------------------ */

    function _quoteBal(AntifragileFloorHook h) internal view returns (uint256) {
        return manager.balanceOf(address(h), quote.toId());
    }

    function _ammQuoteOut(Rec memory r) internal pure returns (uint256) {
        return uint256(int256(r.quoteDelta)) + r.fee - r.topUp;
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @dev Hard solvency invariant: hook quote ERC-6909 balance backs reserve + owed platform exactly.
    function _assertSolvent(AntifragileFloorHook h, PoolId id) internal view {
        assertEq(_quoteBal(h), h.reserveQuote() + h.programmableFeeOwed(id, quote), "insolvent: bal != reserve+owed");
    }
}
