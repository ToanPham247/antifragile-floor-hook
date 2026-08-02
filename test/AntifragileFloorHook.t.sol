// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {AntifragileFloorHook} from "../src/AntifragileFloorHook.sol";

/**
 * @notice Minimal scaffold test: mine a permission-matched CREATE2 address, deploy the hook there,
 *         and prove its permission surface is exactly the intended mask 0x10cc. No business logic
 *         is exercised yet (that arrives in later TDD tasks).
 */
contract AntifragileFloorHookTest is Test, Deployers {
    /// @dev The exact intended permission mask for this hook design.
    ///      afterInitialize(1<<12) | beforeSwap(1<<7) | afterSwap(1<<6)
    ///      | beforeSwapReturnDelta(1<<3) | afterSwapReturnDelta(1<<2) = 0x10cc
    uint160 internal constant EXPECTED_MASK = 0x10cc;

    uint16 internal constant FEE_TOTAL_BPS = 3000;

    AntifragileFloorHook internal hook;

    function setUp() public {
        // Deploy a fresh v4 PoolManager + standard test routers (sets `manager`).
        deployFreshManagerAndRouters();

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        // Sanity: the flag set we mine for is exactly the intended mask.
        assertEq(uint256(flags), uint256(EXPECTED_MASK), "flag set != 0x10cc");

        bytes memory constructorArgs = abi.encode(IPoolManager(address(manager)), FEE_TOTAL_BPS);

        // Mine a CREATE2 salt whose resulting address encodes the required permission bits.
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(AntifragileFloorHook).creationCode, constructorArgs);

        // Deploy at the mined address. BaseHook's constructor re-validates the address<->permission
        // match, so a wrong mask here would revert deployment.
        hook = new AntifragileFloorHook{salt: salt}(IPoolManager(address(manager)), FEE_TOTAL_BPS);
        assertEq(address(hook), hookAddress, "deployed address != mined address");
    }

    /// @notice The deployed hook address' low 14 bits equal the intended mask 0x10cc.
    function test_hookAddress_encodesMask0x10cc() public view {
        uint160 lowBits = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        assertEq(uint256(lowBits), uint256(EXPECTED_MASK), "address low bits != 0x10cc");
    }

    /// @notice getHookPermissions() returns exactly the five enabled flags and nothing else.
    function test_getHookPermissions_exactlyFiveFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();

        // Enabled.
        assertTrue(p.afterInitialize, "afterInitialize should be enabled");
        assertTrue(p.beforeSwap, "beforeSwap should be enabled");
        assertTrue(p.afterSwap, "afterSwap should be enabled");
        assertTrue(p.beforeSwapReturnDelta, "beforeSwapReturnDelta should be enabled");
        assertTrue(p.afterSwapReturnDelta, "afterSwapReturnDelta should be enabled");

        // Disabled (all others).
        assertFalse(p.beforeInitialize, "beforeInitialize should be disabled");
        assertFalse(p.beforeAddLiquidity, "beforeAddLiquidity should be disabled");
        assertFalse(p.afterAddLiquidity, "afterAddLiquidity should be disabled");
        assertFalse(p.beforeRemoveLiquidity, "beforeRemoveLiquidity should be disabled");
        assertFalse(p.afterRemoveLiquidity, "afterRemoveLiquidity should be disabled");
        assertFalse(p.beforeDonate, "beforeDonate should be disabled");
        assertFalse(p.afterDonate, "afterDonate should be disabled");
        assertFalse(p.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta should be disabled");
        assertFalse(p.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta should be disabled");
    }

    /// @notice Constructor wiring: PoolManager + configured fee are stored.
    function test_constructor_wiring() public view {
        assertEq(address(hook.poolManager()), address(manager), "poolManager mismatch");
        assertEq(uint256(hook.feeTotalBps()), uint256(FEE_TOTAL_BPS), "feeTotalBps mismatch");
    }
}
