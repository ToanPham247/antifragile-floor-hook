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

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {AntifragileFloorHook} from "../src/AntifragileFloorHook.sol";

/**
 * @notice ERC-20 that, while armed, tries to REENTER the PoolManager lock and the hook's PoolManager-gated
 *         callbacks on every transfer/transferFrom. It swallows the (expected) reverts so we can observe
 *         whether any reentrancy avenue succeeded, while the outer swap proceeds.
 */
contract ReentrantERC20 is MockERC20 {
    IPoolManager public manager;
    address public hook;
    bool public armed;

    // records of reentrancy outcomes (must all stay false)
    bool public reenteredManagerUnlock;
    bool public reenteredHookUnlockCallback;
    uint256 public attempts;

    constructor() MockERC20("REENTER", "RE", 18) {}

    function wire(IPoolManager _m, address _hook) external {
        manager = _m;
        hook = _hook;
    }

    function arm(bool on) external {
        armed = on;
    }

    function _attack() internal {
        if (!armed || address(manager) == address(0)) return;
        attempts++;
        // (1) try to re-enter the core lock (must revert: manager already unlocked)
        try manager.unlock(bytes("")) {
            reenteredManagerUnlock = true;
        } catch {}
        // (2) try to drive the hook's PoolManager-gated unlockCallback directly (must revert NotPoolManager)
        (bool ok,) = hook.call(abi.encodeWithSelector(AntifragileFloorHook.unlockCallback.selector, bytes("")));
        if (ok) reenteredHookUnlockCallback = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _attack();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _attack();
        return super.transferFrom(from, to, amount);
    }
}

/// @notice ERC-20 that reverts on every transfer to simulate a hostile / reverting counterparty.
contract RevertingERC20 is MockERC20 {
    bool public hostile;

    constructor() MockERC20("REVERT", "RV", 18) {}

    function setHostile(bool on) external {
        hostile = on;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!hostile, "reverting-token");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!hostile, "reverting-token");
        return super.transferFrom(from, to, amount);
    }
}

contract ReentrancyTest is Test, Deployers {
    uint160 internal constant FLAGS = 0x10cc;
    uint24 internal constant FEE = 3000;
    int24 internal constant TS = 60;
    int24 internal constant WIDE_LOWER = -887220;
    int24 internal constant WIDE_UPPER = 887220;

    function setUp() public {
        deployFreshManagerAndRouters();
    }

    function _deployHook(Currency quote) internal returns (AntifragileFloorHook h) {
        bytes memory args = abi.encode(IPoolManager(address(manager)), uint16(3000), quote);
        (address addr, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(AntifragileFloorHook).creationCode, args);
        h = new AntifragileFloorHook{salt: salt}(IPoolManager(address(manager)), uint16(3000), quote);
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

    function _hookClaims(AntifragileFloorHook h, Currency q) internal view returns (uint256) {
        return manager.balanceOf(address(h), q.toId());
    }

    /* ================================================================== */
    /*  A reentrant token as TKN cannot drive a reentrant drain            */
    /* ================================================================== */

    function test_reentrantToken_asTkn_blocked() public {
        _runReentrant(false);
    }

    function test_reentrantToken_asQuote_blocked() public {
        _runReentrant(true);
    }

    function _runReentrant(bool maliciousIsQuote) internal {
        ReentrantERC20 evil = new ReentrantERC20();
        MockERC20 good = new MockERC20("GOOD", "GD", 18);
        (currency0, currency1) = SortTokens.sort(MockERC20(address(evil)), good);

        Currency quote = maliciousIsQuote ? Currency.wrap(address(evil)) : Currency.wrap(address(good));
        Currency tkn = maliciousIsQuote ? Currency.wrap(address(good)) : Currency.wrap(address(evil));

        // controlled supply on the TKN side; abundant on the quote side
        MockERC20(Currency.unwrap(tkn)).mint(address(this), 3000e18);
        MockERC20(Currency.unwrap(quote)).mint(address(this), 1e30);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        AntifragileFloorHook h = _deployHook(quote);
        (PoolKey memory key, PoolId id) = _initPool(h);
        evil.wire(IPoolManager(address(manager)), address(h));

        // seed reserve so there is something a reentrancy could try to steal
        bool buyZeroForOne = (quote == currency0);
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

        uint256 reserveBefore = h.reserveQuote();
        uint256 claimsBefore = _hookClaims(h, quote);
        assertGt(reserveBefore, 0, "reserve should be seeded");

        // ARM the token and run a normal swap: every transfer now tries to reenter.
        evil.arm(true);
        bool sellZeroForOne = (tkn == currency0);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: sellZeroForOne,
                amountSpecified: -int256(10e18),
                sqrtPriceLimitX96: sellZeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // The token DID attempt reentrancy during settlement, but every avenue was blocked.
        assertGt(evil.attempts(), 0, "reentrancy should have been attempted during settlement");
        assertFalse(evil.reenteredManagerUnlock(), "PoolManager lock was re-entered!");
        assertFalse(evil.reenteredHookUnlockCallback(), "hook.unlockCallback was driven by a non-manager!");

        // Solvency preserved; reserve not drained by the reentrancy (a normal sell may add fee to reserve).
        assertEq(_hookClaims(h, quote), h.reserveQuote() + h.programmableFeeOwed(id, quote), "insolvent after reentrancy");
        assertGe(h.reserveQuote(), reserveBefore, "reserve was reduced by a reentrant call");
        assertGe(_hookClaims(h, quote), claimsBefore, "claims reduced by a reentrant call");
    }

    /* ================================================================== */
    /*  Hook callbacks are strictly onlyPoolManager (no self / reentry)    */
    /* ================================================================== */

    function test_callbacks_onlyPoolManager() public {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (currency0, currency1) = SortTokens.sort(a, b);
        AntifragileFloorHook h = _deployHook(currency0);
        PoolKey memory key = PoolKey(currency0, currency1, FEE, TS, IHooks(address(h)));
        SwapParams memory p = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

        vm.expectRevert(BaseHook.NotPoolManager.selector);
        h.beforeSwap(address(this), key, p, ZERO_BYTES);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        h.afterSwap(address(this), key, p, BalanceDelta.wrap(0), ZERO_BYTES);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        h.unlockCallback(bytes(""));
        // afterInitialize is also gated
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        h.afterInitialize(address(this), key, SQRT_PRICE_1_1, int24(0));
    }

    /* ================================================================== */
    /*  A reverting counterparty token => swap reverts atomically, no loss */
    /* ================================================================== */

    function test_revertingToken_atomicNoStuckState() public {
        RevertingERC20 rv = new RevertingERC20();
        MockERC20 good = new MockERC20("GOOD", "GD", 18);
        (currency0, currency1) = SortTokens.sort(good, MockERC20(address(rv)));

        // quote = good (abundant), tkn = reverting token
        Currency quote = Currency.wrap(address(good));
        Currency tkn = Currency.wrap(address(rv));
        MockERC20(Currency.unwrap(tkn)).mint(address(this), 3000e18);
        MockERC20(Currency.unwrap(quote)).mint(address(this), 1e30);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        AntifragileFloorHook h = _deployHook(quote);
        (PoolKey memory key, PoolId id) = _initPool(h);

        bool buyZeroForOne = (quote == currency0);
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

        uint256 reserveBefore = h.reserveQuote();
        uint256 floorBefore = h.floorHigh();
        uint256 claimsBefore = _hookClaims(h, quote);

        // Now make the TKN hostile and attempt a sell (TKN in). Settlement transfer reverts => whole tx reverts.
        rv.setHostile(true);
        bool sellZeroForOne = (tkn == currency0);
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: sellZeroForOne,
                amountSpecified: -int256(50e18),
                sqrtPriceLimitX96: sellZeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // No partial state: reserve, floor, liability and claims are exactly as before the reverted swap.
        assertEq(h.reserveQuote(), reserveBefore, "reserve changed by a reverted swap");
        assertEq(h.floorHigh(), floorBefore, "floor changed by a reverted swap");
        assertEq(_hookClaims(h, quote), claimsBefore, "claims changed by a reverted swap");
        assertEq(_hookClaims(h, quote), h.reserveQuote() + h.programmableFeeOwed(id, quote), "insolvent");
    }
}
