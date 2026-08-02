// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
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
import {FloorMath} from "../../src/lib/FloorMath.sol";

/**
 * @title Antifragile Floor — mainnet-fork harness
 * @notice Shared harness that binds the REAL Ethereum-mainnet Uniswap v4 PoolManager singleton
 *         (NOT a fresh Deployers-deployed one) and exercises the hook against that real runtime.
 *
 * @dev We inherit {Deployers} only to reuse its constants (SQRT_PRICE_1_1, MIN/MAX_PRICE_LIMIT,
 *      ZERO_BYTES) and the `manager`/`swapRouter`/`modifyLiquidityRouter`/`currency0`/`currency1`
 *      fields. We do NOT call `deployFreshManagerAndRouters()` (that deploys a fresh PoolManager).
 *      Instead {_bindRealManager} points `manager` at the canonical mainnet address and deploys
 *      only the stateless test routers against it. Fresh MockERC20 tokens are deployed ON the fork
 *      (never scarce real tokens) and minted to the tester.
 */
abstract contract AntifragileForkHarness is Test, Deployers {
    /// @notice Canonical Ethereum-mainnet v4 PoolManager singleton (deployment record v4-poolmanager-ethereum).
    address internal constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    /// @notice The runtime codehash observed live at block 25666892 (see deployment-evidence.json).
    bytes32 internal constant EXPECTED_POOL_MANAGER_CODEHASH =
        0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293;

    uint160 internal constant FLAGS = 0x10cc;
    address internal constant HOOK_OWNER = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;
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

    /// @dev Resolve the fork RPC: MAINNET_RPC_URL env, else the public fallback (a public read RPC).
    function _rpc() internal view returns (string memory) {
        return vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
    }

    /// @dev Point `manager` at the REAL mainnet PoolManager and deploy the stateless test routers
    ///      against it. Asserts the forked runtime is the expected canonical bytecode.
    function _bindRealManager() internal {
        assertGt(MAINNET_POOL_MANAGER.code.length, 0, "no code at mainnet PoolManager on fork");
        manager = IPoolManager(MAINNET_POOL_MANAGER);
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
    }

    /* ------------------------------------------------------------------ */
    /*                      Harness (mirrors FloorHonor)                   */
    /* ------------------------------------------------------------------ */

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

    /// @dev Seed the reserve via a BEFORE-quadrant exact-input BUY (fee on the full specified quote
    ///      input => reserve += project(quoteIn) exactly, independent of pool depth).
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
    }

    function _swap(AntifragileFloorHook h, PoolKey memory key, PoolId id, bool zeroForOne, int256 amtSpec)
        internal
        returns (Rec memory r)
    {
        r.reserveBefore = h.reserveQuote();

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
        id; // silence unused in some paths
    }

    function _quoteBal(AntifragileFloorHook h) internal view returns (uint256) {
        return manager.balanceOf(address(h), quote.toId());
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    function _ammQuoteOut(Rec memory r) internal pure returns (uint256) {
        return uint256(int256(r.quoteDelta)) + r.fee - r.topUp;
    }

    /// @dev Solvency: hook's quote ERC-6909 claim balance backs reserve + owed exactly.
    function _assertSolvent(AntifragileFloorHook h, PoolId id) internal view {
        assertEq(
            _quoteBal(h),
            h.reserveQuote() + h.programmableFeeOwed(id, quote),
            "insolvent: bal != reserve+owed"
        );
    }
}

/**
 * @notice PINNED-BLOCK fork test. Forks Ethereum mainnet at block 25666892 (the block whose observed
 *         PoolManager runtime codehash is recorded in deployment-evidence.json), binds the REAL
 *         singleton, mines+deploys the hook, initializes a canonical pool, adds liquidity, then runs a
 *         BUY (seeds the reserve), a SELL (fee accrual), and a reserve-funded floor TOP-UP — asserting
 *         fee accrual and the hard solvency invariant hold against the real PoolManager runtime.
 */
contract AntifragileForkPinnedTest is AntifragileForkHarness {
    uint256 internal constant FORK_BLOCK = 25666892;

    function setUp() public {
        vm.createSelectFork(_rpc(), FORK_BLOCK);
        // Prove we are on the exact real runtime whose identity is bound in deployment-evidence.json.
        assertEq(MAINNET_POOL_MANAGER.codehash, EXPECTED_POOL_MANAGER_CODEHASH, "PoolManager runtime codehash mismatch");
        assertEq(block.number, FORK_BLOCK, "fork not pinned to expected block");
        _bindRealManager();
    }

    /// @notice The pinned block's PoolManager code is exactly the canonical runtime we observed off-chain.
    function test_fork_realPoolManager_identity() public view {
        assertEq(MAINNET_POOL_MANAGER.codehash, EXPECTED_POOL_MANAGER_CODEHASH, "codehash");
        assertEq(address(manager), MAINNET_POOL_MANAGER, "manager bound to real singleton");
    }

    /// @notice End-to-end against the real PoolManager: buy (seed) -> sell (fee) -> floor top-up, solvent.
    function test_fork_buy_sell_topUp_againstRealPoolManager() public {
        // backedSupply = 3000 TKN (modest => a meaningful floor); quote = currency1.
        _mkTokens(3000e18, false);
        AntifragileFloorHook h = _deployHook(3000); // 30% fee
        (PoolKey memory key, PoolId id) = _init(h);
        _assertSolvent(h, id);

        // ---- BUY (exact-input, quote in) grows the reserve; fee must accrue. ----
        Rec memory buy = _swap(h, key, id, false, -int256(50e18));
        assertGt(buy.fee, 0, "buy must accrue a fee");
        assertGt(buy.project, 0, "buy must grow the reserve (project slice)");
        assertEq(buy.reserveAfter, buy.reserveBefore + buy.project, "reserve grew by project slice");
        assertFalse(buy.toppedUp, "buy must not be topped up");
        _assertSolvent(h, id);

        // Grow the reserve further so the floor sits well above zero.
        _seedReserve(key, 1000e18);
        uint256 floorHigh = h.floorHigh();
        assertGt(floorHigh, 0, "floor did not grow");
        assertEq(floorHigh, FloorMath.floorPrice(h.reserveQuote(), 3000e18), "floor != reserve/supply");
        _assertSolvent(h, id);

        // ---- SELL below the floor: thin the pool so the AMM prices far below the floor. ----
        _modLiq(key, -(FULL_LIQ - int256(1e18)));
        uint256 sellTkn = 1500e18;
        uint256 targetGross = (floorHigh * sellTkn) / WAD;

        Rec memory sell = _swap(h, key, id, true, -int256(sellTkn)); // zeroForOne sell (quote=currency1)

        // Fee accrued on the executed swap.
        assertGt(sell.fee, 0, "sell must accrue a fee");
        // Reserve-funded top-up happened.
        assertTrue(sell.toppedUp, "expected a floor top-up on the below-floor sell");
        assertGt(sell.topUp, 0, "topUp must be > 0");
        assertEq(sell.reserveAfter, sell.reserveBefore + sell.project - sell.topUp, "reserve accounting");
        assertLt(sell.reserveAfter, sell.reserveBefore, "reserve net-decreased (topUp >> fee)");

        // Floor honored: gross (sellerNet + fee) reached the target within rounding dust.
        uint256 sellerNet = uint256(int256(sell.quoteDelta));
        uint256 gross = sellerNet + sell.fee; // == ammOut + topUp
        assertGe(gross, targetGross - 1, "gross below floor target");
        // The AMM alone would have paid far less — proves the subsidy did the work.
        assertLt(_ammQuoteOut(sell), targetGross / 2, "AMM should have priced well below the floor");

        // Fee basis is the executed ammQuoteOut, NOT the subsidised gross.
        uint256 ammOut = _ammQuoteOut(sell);
        assertEq(sell.fee, _ceilDiv(ammOut * h.effectiveRate(), RATE_DENOM), "fee not on executed ammQuoteOut");

        // Hard invariant against the REAL PoolManager runtime.
        _assertSolvent(h, id);
    }
}

/**
 * @notice CURRENT-HEAD smoke test. Forks at the latest block, binds the REAL singleton, initializes a
 *         canonical pool + liquidity, and does one swap — a minimal liveness proof that the hook
 *         deploys, binds and swaps against whatever runtime is live at head today.
 */
contract AntifragileForkHeadSmokeTest is AntifragileForkHarness {
    function setUp() public {
        vm.createSelectFork(_rpc()); // latest block
        _bindRealManager();
    }

    function test_fork_head_initAndOneSwap_smoke() public {
        assertGt(MAINNET_POOL_MANAGER.code.length, 0, "no PoolManager code at head");

        _mkTokens(3000e18, false);
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);
        _assertSolvent(h, id);

        // one exact-input BUY (quote in) — must accrue a fee and stay solvent at head.
        Rec memory r = _swap(h, key, id, false, -int256(25e18));
        assertGt(r.fee, 0, "smoke swap must accrue a fee against the head runtime");
        _assertSolvent(h, id);
    }
}
