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
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {AntifragileFloorHook} from "../../src/AntifragileFloorHook.sol";

/// @notice Handler that drives swaps on TWO independent hook+pool deployments with DIFFERENT currencies.
contract TwoPoolHandler {
    uint160 internal constant MIN_PRICE_LIMIT = 4295128739 + 1;
    uint160 internal constant MAX_PRICE_LIMIT = 1461446703485210103287273052203988822378723970342 - 1;

    PoolSwapTest internal immutable swapRouter;
    PoolKey internal keyA;
    PoolKey internal keyB;
    bool internal immutable sellA0; // sell direction on pool A
    bool internal immutable sellB0;

    uint256 public okA;
    uint256 public okB;

    constructor(PoolSwapTest _r, PoolKey memory _keyA, PoolKey memory _keyB, bool _sellA0, bool _sellB0) {
        swapRouter = _r;
        keyA = _keyA;
        keyB = _keyB;
        sellA0 = _sellA0;
        sellB0 = _sellB0;
    }

    function _amt(uint256 x) internal pure returns (uint256) {
        return 1e12 + (x % (1e18 - 1e12 + 1));
    }

    function _swap(PoolKey storage k, bool zeroForOne, int256 amtSpec) internal {
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amtSpec,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
    }

    function sellA(uint256 x) external {
        _swap(keyA, sellA0, -int256(_amt(x)));
        okA++;
    }

    function buyA(uint256 x) external {
        _swap(keyA, !sellA0, -int256(_amt(x)));
        okA++;
    }

    function sellB(uint256 x) external {
        _swap(keyB, sellB0, -int256(_amt(x)));
        okB++;
    }

    function buyB(uint256 x) external {
        _swap(keyB, !sellB0, -int256(_amt(x)));
        okB++;
    }
}

/**
 * @notice Two-pool isolation: two AntifragileFloorHook deployments over DIFFERENT currency pairs, fuzzed
 *         concurrently. Asserts each hook's liability + reserve are independent and never net across pools.
 */
contract AntifragileTwoPoolInvariant is Test, Deployers {
    uint160 internal constant FLAGS = 0x10cc;
    uint24 internal constant FEE = 3000;
    int24 internal constant TS = 60;
    int24 internal constant WIDE_LOWER = -887220;
    int24 internal constant WIDE_UPPER = 887220;

    AntifragileFloorHook internal hookA;
    AntifragileFloorHook internal hookB;
    TwoPoolHandler internal handler;

    PoolKey internal keyA;
    PoolKey internal keyB;
    PoolId internal idA;
    PoolId internal idB;
    Currency internal quoteA;
    Currency internal tknA;
    Currency internal quoteB;
    Currency internal tknB;

    function _mkPair(uint256 tknSupply) internal returns (Currency c0, Currency c1) {
        MockERC20 a = new MockERC20("Q", "Q", 18); // quote-ish
        MockERC20 b = new MockERC20("T", "T", 18); // token-ish
        b.mint(address(this), tknSupply);
        a.mint(address(this), 1e30);
        (c0, c1) = SortTokens.sort(a, b);
    }

    function _deploy(uint16 feeBps, Currency quote, address expectedToken) internal returns (AntifragileFloorHook h) {
        // Precommit the exact launch identity of the pool this hook will bind ({_initAndSeed}): the given
        // non-quote token, the canonical 1:1 start price and tick spacing TS.
        bytes memory args =
            abi.encode(IPoolManager(address(manager)), feeBps, quote, expectedToken, SQRT_PRICE_1_1, TS);
        (address addr, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(AntifragileFloorHook).creationCode, args);
        h = new AntifragileFloorHook{salt: salt}(
            IPoolManager(address(manager)), feeBps, quote, expectedToken, SQRT_PRICE_1_1, TS
        );
        require(address(h) == addr, "mine");
    }

    function _approveAll(Currency c0, Currency c1, address who) internal {
        vm.startPrank(who);
        MockERC20(Currency.unwrap(c0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _initAndSeed(AntifragileFloorHook h, Currency c0, Currency c1, Currency quote)
        internal
        returns (PoolKey memory key, PoolId id)
    {
        MockERC20(Currency.unwrap(c0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(swapRouter), type(uint256).max);
        key = PoolKey(c0, c1, FEE, TS, IHooks(address(h)));
        id = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: WIDE_LOWER, tickUpper: WIDE_UPPER, liquidityDelta: int256(1e21), salt: 0}),
            ZERO_BYTES
        );
        // seed reserve (buy = quote in): zeroForOne == (quote == c0)
        bool buyZeroForOne = (quote == c0);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: buyZeroForOne,
                amountSpecified: -int256(1000e18),
                sqrtPriceLimitX96: buyZeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function setUp() public {
        deployFreshManagerAndRouters();

        // Pool A currencies.
        (Currency a0, Currency a1) = _mkPair(4000e18);
        quoteA = a1;
        tknA = a0;
        hookA = _deploy(3000, quoteA, Currency.unwrap(tknA));
        (keyA, idA) = _initAndSeed(hookA, a0, a1, quoteA);

        // Pool B currencies (a completely different pair).
        (Currency b0, Currency b1) = _mkPair(5000e18);
        quoteB = b1;
        tknB = b0;
        hookB = _deploy(500, quoteB, Currency.unwrap(tknB));
        (keyB, idB) = _initAndSeed(hookB, b0, b1, quoteB);

        bool sellA0 = (tknA == keyA.currency0);
        bool sellB0 = (tknB == keyB.currency0);

        handler = new TwoPoolHandler(swapRouter, keyA, keyB, sellA0, sellB0);
        // fund + approve the handler for all four currencies
        MockERC20(Currency.unwrap(a0)).mint(address(handler), 1e24);
        MockERC20(Currency.unwrap(a1)).mint(address(handler), 1e30);
        MockERC20(Currency.unwrap(b0)).mint(address(handler), 1e24);
        MockERC20(Currency.unwrap(b1)).mint(address(handler), 1e30);
        _approveAll(a0, a1, address(handler));
        _approveAll(b0, b1, address(handler));

        targetContract(address(handler));
    }

    function _claims(AntifragileFloorHook h, Currency c) internal view returns (uint256) {
        return manager.balanceOf(address(h), c.toId());
    }

    /// @notice Each hook is independently solvent in ITS OWN quote currency.
    function invariant_eachPoolSolvent() public view {
        assertEq(_claims(hookA, quoteA), hookA.reserveQuote() + hookA.programmableFeeOwed(idA, quoteA), "A insolvent");
        assertEq(_claims(hookB, quoteB), hookB.reserveQuote() + hookB.programmableFeeOwed(idB, quoteB), "B insolvent");
    }

    /// @notice No cross-pool netting: neither hook accrues liability under the OTHER pool's id or currency,
    ///         and neither hook ever holds a claim balance of the other pool's currencies.
    function invariant_noCrossPoolNetting() public view {
        // liability is only ever under (own id, own quote)
        assertEq(hookA.programmableFeeOwed(idB, quoteA), 0, "A owed under B id");
        assertEq(hookA.programmableFeeOwed(idA, quoteB), 0, "A owed in B currency");
        assertEq(hookA.programmableFeeOwed(idB, quoteB), 0, "A owed under B id+currency");
        assertEq(hookB.programmableFeeOwed(idA, quoteB), 0, "B owed under A id");
        assertEq(hookB.programmableFeeOwed(idB, quoteA), 0, "B owed in A currency");
        assertEq(hookB.programmableFeeOwed(idA, quoteA), 0, "B owed under A id+currency");

        // no hook ever holds the other pool's currency claims (would be evidence of cross-pool custody)
        assertEq(_claims(hookA, quoteB), 0, "A holds B-quote claims");
        assertEq(_claims(hookA, tknB), 0, "A holds B-tkn claims");
        assertEq(_claims(hookB, quoteA), 0, "B holds A-quote claims");
        assertEq(_claims(hookB, tknA), 0, "B holds A-tkn claims");
    }

    /// @notice Both pools were actually exercised (coverage proof).
    function afterInvariant() public view {
        assertGt(handler.okA(), 0, "pool A never swapped");
        assertGt(handler.okB(), 0, "pool B never swapped");
    }
}
