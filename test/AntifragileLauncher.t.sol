// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AntifragileFloorHook} from "../src/AntifragileFloorHook.sol";
import {AntifragileToken} from "../src/AntifragileToken.sol";
import {AntifragileLauncher} from "../src/AntifragileLauncher.sol";

/// @notice EXECUTABLE launch-graph proof for the v1 launch specification (submissions/antifragile-floor/launch.json).
///         Deploys the atomic {AntifragileLauncher}, mines the token + hook salts, launches the whole pool in ONE
///         transaction (token -> hook -> initialize -> seed liquidity -> settle) and proves the coin is directly
///         tradable, the hook is bound to exactly the launched token, the mandatory Programmable volume fee accrues
///         solvently, and the launch is single-use and wallet-gated.
contract AntifragileLauncherTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    uint160 constant FLAGS = 0x10cc;
    int24 constant TS = 60;

    // Mirror of AntifragileLauncher's canonical fee constant (10 bps platform + 20 bps floor reserve = 30 bps).
    uint16 constant FEE_TOTAL_BPS = 30;

    string constant NAME = "Antifragile Coin";
    string constant SYMBOL = "AFC";

    MockERC20 quote;
    AntifragileLauncher launcher;

    function setUp() public {
        deployFreshManagerAndRouters();
        quote = new MockERC20("Wrapped Ether", "WETH", 18);
        launcher = new AntifragileLauncher(IPoolManager(address(manager)), IERC20(address(quote)), address(this));
    }

    function _mineAndLaunch(uint256 supply, uint128 liquidity)
        internal
        returns (AntifragileToken token, AntifragileFloorHook hook, PoolKey memory key)
    {
        bytes32 tokenSalt = keccak256("antifragile-token");
        // Predict the token address the launcher will CREATE2, so the hook's EXPECTED_TOKEN can be mined in.
        bytes32 tokenInitHash = keccak256(
            abi.encodePacked(type(AntifragileToken).creationCode, abi.encode(NAME, SYMBOL, supply, address(launcher)))
        );
        address predictedToken = vm.computeCreate2Address(tokenSalt, tokenInitHash, address(launcher));

        // Reconstruct the exact 6-arg hook ctor args the launcher will use (with the predicted token precommitted).
        bytes memory hookArgs = abi.encode(
            address(manager), FEE_TOTAL_BPS, Currency.wrap(address(quote)), predictedToken, SQRT_PRICE_1_1, TS
        );
        // The launcher is the CREATE2 deployer of the hook, so mine against the launcher address.
        (address hookAddr, bytes32 hookSalt) =
            HookMiner.find(address(launcher), FLAGS, type(AntifragileFloorHook).creationCode, hookArgs);

        // Fund + approve the launch wallet (this test) for the quote-side liquidity.
        quote.mint(address(this), 1e24);
        quote.approve(address(launcher), type(uint256).max);

        AntifragileLauncher.LaunchParams memory params = AntifragileLauncher.LaunchParams({
            name: NAME,
            symbol: SYMBOL,
            totalSupply: supply,
            tokenSalt: tokenSalt,
            hookSalt: hookSalt,
            tickSpacing: TS,
            sqrtPriceX96: SQRT_PRICE_1_1,
            liquidity: liquidity,
            maxToken: type(uint256).max,
            maxQuote: 1e24
        });

        (token, hook) = launcher.deployAndLaunch(params);
        assertEq(address(hook), hookAddr, "hook deployed at mined address");
        assertEq(address(token), predictedToken, "token deployed at predicted address");

        (Currency c0, Currency c1) = address(token) < address(quote)
            ? (Currency.wrap(address(token)), Currency.wrap(address(quote)))
            : (Currency.wrap(address(quote)), Currency.wrap(address(token)));
        key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TS, IHooks(address(hook)));
    }

    /// Full atomic launch: one transaction deploys token + hook, initialises the canonical dynamic-fee pool,
    /// seeds full-range liquidity; then the coin is directly tradable and the mandatory fee accrues solvently.
    function test_launch_atomic_tradable() public {
        (AntifragileToken token, AntifragileFloorHook hook, PoolKey memory key) = _mineAndLaunch(1e24, 1e21);
        PoolId id = key.toId();

        // Hook bound to exactly the launched token + this pool, with the supply snapshot frozen at bind.
        assertEq(Currency.unwrap(hook.tknCurrency()), address(token), "hook bound the launched token");
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(id), "hook bound the launched pool");
        assertEq(hook.backedSupplySnapshot(), 1e24, "supply snapshot frozen at the fixed launch supply");
        assertGt(manager.getLiquidity(id), 0, "pool seeded with liquidity");

        // The coin is directly tradable: sell the launched token for quote, the mandatory fee accrues, the hook
        // stays solvent. An exact-input sell of the token (token specified => quote is UNSPECIFIED, after-quadrant)
        // takes the plain executed-basis fee with no precommit partial-fill guard. The launch returned all unspent
        // token supply to this launch wallet, so we trade with that (the token is fixed-supply, cannot be minted).
        Currency quoteCurrency = Currency.wrap(address(quote));
        bool quoteIs0 = key.currency0 == quoteCurrency;
        assertGt(token.balanceOf(address(this)), 1e18, "launch returned unspent token to the launch wallet");
        IERC20(address(token)).approve(address(swapRouter), type(uint256).max);
        quote.approve(address(swapRouter), type(uint256).max);

        bool zeroForOne = !quoteIs0; // sell the token (the non-quote side) for quote
        swapRouter.swap(
            key,
            SwapParams(zeroForOne, -int256(1e18), zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false),
            ""
        );

        // Mandatory fee accrued (platform liability + floor reserve), and the hook's ERC-6909 quote claims back it
        // 1:1 (solvent by construction).
        uint256 owed = hook.programmableFeeOwed(id, quoteCurrency) + hook.reserveQuote();
        assertGt(owed, 0, "mandatory fee accrued on the first trade");
        assertEq(manager.balanceOf(address(hook), quoteCurrency.toId()), owed, "hook 6909 solvency == owed");
    }

    /// The launch is single-use: a second deployAndLaunch reverts.
    function test_launch_single_use() public {
        _mineAndLaunch(1e24, 1e21);
        AntifragileLauncher.LaunchParams memory params;
        params.name = "X";
        params.symbol = "X";
        params.totalSupply = 1;
        params.tickSpacing = TS;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        vm.expectRevert(AntifragileLauncher.AlreadyLaunched.selector);
        launcher.deployAndLaunch(params);
    }

    /// Only the launch wallet can launch.
    function test_launch_only_wallet() public {
        AntifragileLauncher.LaunchParams memory params;
        params.tickSpacing = TS;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        vm.prank(address(0xBEEF));
        vm.expectRevert(AntifragileLauncher.NotLaunchWallet.selector);
        launcher.deployAndLaunch(params);
    }
}
