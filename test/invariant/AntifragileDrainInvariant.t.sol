// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
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
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {AntifragileFloorHook} from "../../src/AntifragileFloorHook.sol";

/**
 * @notice Handler whose sell action deliberately PARTIAL-FILLS via a tight `sqrtPriceLimitX96`. This is the
 *         adversarial input the "standard" solvency invariants cannot model — the seller parts with dust TKN
 *         but the hook sizes the floor top-up on the FULL requested amount.
 */
contract DrainHandler {
    using StateLibrary for IPoolManager;

    IPoolManager internal immutable manager;
    PoolSwapTest internal immutable swapRouter;
    AntifragileFloorHook internal immutable hook;
    PoolKey internal key;
    PoolId internal immutable id;
    Currency internal immutable quote;
    Currency internal immutable tkn;
    bool internal immutable sellZeroForOne;

    uint256 public sells;
    // Worst observed over-subsidy (for the counterexample readout).
    bool public overSubsidyObserved;
    uint256 public worstQuoteReceived;
    uint256 public worstFairFloorValue;
    uint256 public worstTknGivenUp;

    constructor(IPoolManager _m, PoolSwapTest _r, AntifragileFloorHook _h, PoolKey memory _key, Currency _q, Currency _t) {
        manager = _m;
        swapRouter = _r;
        hook = _h;
        key = _key;
        id = _key.toId();
        quote = _q;
        tkn = _t;
        sellZeroForOne = (_t == _key.currency0);
    }

    /// @notice Tight-limit exact-input sell: requests a large amount but only DUST executes.
    function partialFillSell(uint256 rawReq) external {
        uint256 requested = 1e18 + (rawReq % (3000e18 - 1e18 + 1)); // request 1..3000 TKN
        (uint160 curSqrt,,,) = manager.getSlot0(id);
        // A limit ~0.001% past spot in the swap's direction => the swap stalls after dust.
        uint160 lim = sellZeroForOne ? curSqrt - (curSqrt / 100000) : curSqrt + (curSqrt / 100000);

        uint256 floorHigh = hook.floorHigh();
        uint256 tBefore = MockERC20(Currency.unwrap(tkn)).balanceOf(address(this));
        uint256 qBefore = MockERC20(Currency.unwrap(quote)).balanceOf(address(this));

        swapRouter.swap(
            key,
            SwapParams({zeroForOne: sellZeroForOne, amountSpecified: -int256(requested), sqrtPriceLimitX96: lim}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        uint256 tknGivenUp = tBefore - MockERC20(Currency.unwrap(tkn)).balanceOf(address(this));
        uint256 quoteReceived = MockERC20(Currency.unwrap(quote)).balanceOf(address(this)) - qBefore;
        uint256 fairFloorValue = (tknGivenUp * floorHigh) / 1e18;

        // Over-subsidy: received MORE than 1 whole QUOTE beyond the floor-value of the TKN actually delivered.
        // (Legit dust output is << 1 QUOTE; the exploit pays out tens/hundreds of QUOTE for dust.)
        if (quoteReceived > fairFloorValue + 1e18) {
            overSubsidyObserved = true;
            if (quoteReceived > worstQuoteReceived) {
                worstQuoteReceived = quoteReceived;
                worstFairFloorValue = fairFloorValue;
                worstTknGivenUp = tknGivenUp;
            }
        }
        sells++;
    }
}

/**
 * @notice ADVERSARIAL invariant that DOES catch the reserve-drain the standard suite misses:
 *         a seller must never receive QUOTE materially beyond the floor-value of the TKN they actually
 *         delivered. This invariant is EXPECTED TO FAIL against the current hook — that failure IS the bug.
 *         (Root cause + fix in the report; PoC in test/ReserveDrainExploit.t.sol.)
 */
contract AntifragileDrainInvariant is Test, Deployers {
    using StateLibrary for IPoolManager;

    uint160 internal constant FLAGS = 0x10cc;
    uint24 internal constant FEE = 3000;
    int24 internal constant TS = 60;
    int24 internal constant WIDE_LOWER = -887220;
    int24 internal constant WIDE_UPPER = 887220;

    AntifragileFloorHook internal hook;
    DrainHandler internal handler;
    PoolKey internal poolKey;
    PoolId internal poolId;
    Currency internal quote;
    Currency internal tkn;

    function setUp() public {
        deployFreshManagerAndRouters();

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (currency0, currency1) = SortTokens.sort(a, b);
        quote = currency1;
        tkn = currency0;
        MockERC20(Currency.unwrap(tkn)).mint(address(this), 3000e18);
        MockERC20(Currency.unwrap(quote)).mint(address(this), 1e30);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);

        // Precommit the exact launch identity of the pool bound below: the non-quote token `tkn`,
        // the canonical 1:1 start price and tick spacing TS.
        address expectedToken = Currency.unwrap(tkn);
        bytes memory args =
            abi.encode(IPoolManager(address(manager)), uint16(3000), quote, expectedToken, SQRT_PRICE_1_1, TS);
        (address addr, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(AntifragileFloorHook).creationCode, args);
        hook = new AntifragileFloorHook{salt: salt}(
            IPoolManager(address(manager)), uint16(3000), quote, expectedToken, SQRT_PRICE_1_1, TS
        );
        require(address(hook) == addr, "mine");
        poolKey = PoolKey(currency0, currency1, FEE, TS, IHooks(address(hook)));
        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: WIDE_LOWER, tickUpper: WIDE_UPPER, liquidityDelta: int256(1e21), salt: 0}),
            ZERO_BYTES
        );
        // Seed a healthy reserve so there is something to steal.
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(1000e18), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        assertGt(hook.floorHigh(), 0, "floor not active");

        handler = new DrainHandler(IPoolManager(address(manager)), swapRouter, hook, poolKey, quote, tkn);
        MockERC20(Currency.unwrap(tkn)).mint(address(handler), 1e24);
        vm.prank(address(handler));
        MockERC20(Currency.unwrap(tkn)).approve(address(swapRouter), type(uint256).max);

        targetContract(address(handler));
    }

    /// @notice A seller must never receive QUOTE materially beyond the floor-value of the TKN they delivered.
    ///         EXPECTED TO FAIL: the partial-fill top-up over-subsidizes on the requested (not executed) amount.
    function invariant_topUpFairness_noReserveDrain() public view {
        assertFalse(
            handler.overSubsidyObserved(),
            "DRAIN: seller received QUOTE far beyond floor-value of TKN delivered (see worst* getters)"
        );
    }
}
