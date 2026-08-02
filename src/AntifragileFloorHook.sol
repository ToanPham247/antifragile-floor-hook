// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/**
 * @title AntifragileFloorHook
 * @notice Skeleton for the Antifragile Floor hook: a Uniswap v4 hook intended to maintain a
 *         self-funded, monotonic on-chain price floor (Programmable Hookathon).
 *
 * @dev This is an intentionally logic-free scaffold. It fixes the exact permission surface the
 *      design requires and provides the minimal, valid stub callbacks so the project compiles and
 *      deploys at a permission-matched address. Business logic (floor accounting, fee capture, the
 *      Programmable volume-fee policy, custody and claims) is added in later TDD tasks.
 *
 *      Enabled callbacks (permission mask = 0x10cc):
 *        - afterInitialize        (1 << 12 = 0x1000)
 *        - beforeSwap             (1 <<  7 = 0x0080)
 *        - afterSwap              (1 <<  6 = 0x0040)
 *        - beforeSwapReturnDelta  (1 <<  3 = 0x0008)
 *        - afterSwapReturnDelta   (1 <<  2 = 0x0004)
 *      All other permissions are disabled.
 */
contract AntifragileFloorHook is BaseHook {
    /// @notice Total fee, in basis points, the hook is configured with (no logic wired yet).
    uint16 public immutable feeTotalBps;

    /**
     * @param _pm The Uniswap v4 PoolManager singleton.
     * @param _feeTotalBps The configured total fee in basis points.
     *
     * @dev `BaseHook`'s constructor calls `validateHookAddress(this)`, so this contract can only be
     *      deployed at an address whose low bits encode exactly the permissions returned by
     *      {getHookPermissions} (mask 0x10cc). Deployments therefore use a mined CREATE2 salt.
     */
    constructor(IPoolManager _pm, uint16 _feeTotalBps) BaseHook(_pm) {
        feeTotalBps = _feeTotalBps;
    }

    /**
     * @inheritdoc BaseHook
     * @dev Declares exactly the five callbacks this hook design uses. Yields permission mask 0x10cc.
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /**
     * @dev Stub for `afterInitialize`. No floor is seeded yet; simply acknowledges the callback.
     */
    function _afterInitialize(address, PoolKey calldata, uint160, int24)
        internal
        virtual
        override
        returns (bytes4)
    {
        return IHooks.afterInitialize.selector;
    }

    /**
     * @dev Stub for `beforeSwap`. Returns a zero delta so no value is moved (no logic yet).
     */
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, uint24(0));
    }

    /**
     * @dev Stub for `afterSwap`. Returns a zero hook delta so no value is moved (no logic yet).
     */
    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, int128(0));
    }
}
