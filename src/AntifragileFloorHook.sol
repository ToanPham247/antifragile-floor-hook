// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/**
 * @title AntifragileFloorHook
 * @notice Uniswap v4 hook implementing the mandatory Programmable volume-fee policy
 *         `programmable-volume-fee-v1` for the Antifragile Floor.
 *
 * @dev POLICY SUMMARY (see docs/ for the full spec):
 *
 *      RATES are in hundredths-of-a-bip: `1000 = 10 bps = 0.10%`.
 *        - `selected`  = total hook-owned swap charge = `feeTotalBps * 100`.
 *        - `effective` = `max(selected, 1000)`  (a 10 bps floor).
 *        - `platform`  = 1000 (exactly 10 bps) — accrued as an owner-only CLAIMABLE LIABILITY.
 *        - `project`   = `effective - 1000`     — accrued into the floor `reserveQuote`.
 *      The split is NON-ADDITIVE: 3% never becomes 3.1%; the 10 bps platform is carved OUT of the
 *      total, so `platform + project == total` exactly.
 *
 *      BASIS is the executed GROSS quote-side swap volume, in the pool's quote asset, measured on
 *      the ACTUAL executed amount (post partial-fill), BEFORE deducting portions.
 *
 *      QUADRANT-DEPENDENT RETURN-DELTA COLLECTION (quote can be currency0 or currency1):
 *
 *        | quote asset | zeroForOne exactIn | zeroForOne exactOut | oneForZero exactIn | oneForZero exactOut |
 *        | currency0   | before             | after               | after              | before              |
 *        | currency1   | after              | before              | before             | after               |
 *
 *      "before" = collect via `beforeSwapReturnDelta` — quote is the SPECIFIED currency, its amount
 *                 is known pre-swap (`|amountSpecified|`).
 *      "after"  = collect via `afterSwap` return delta — quote is the UNSPECIFIED currency, its
 *                 executed amount is known post-swap (from the swap `BalanceDelta`).
 *      This whole table reduces to a single predicate: collect BEFORE iff the quote currency is the
 *      swap's specified currency, else collect AFTER. See {_beforeSwap}/{_afterSwap}.
 *
 *      OWNER + CUSTODY: the owner is the immutable constant {OWNER}. Both the platform liability and
 *      the project reserve are held as this hook's ERC-6909 claim balances of the quote currency.
 *      The platform liability is keyed by `(poolId, currency)` and is paid out only by
 *      {claimProgrammableFee} — owner-only, to an owner-selected destination per claim. There is no
 *      stored mutable recipient, and no cross-pool netting.
 *
 *      selfCallPolicy = same-pool-swap-forbidden: this hook NEVER initiates a swap on its own pool
 *      (it contains no `poolManager.swap` call). v4 additionally no-ops hook callbacks on self-calls
 *      (see `Hooks.beforeSwap`/`afterSwap`), and all hook entry points are `onlyPoolManager`.
 *
 *      ROUNDING is in the protocol's favor — fee amounts round UP (ceil). The swap is charged at
 *      least the nominal rate, never less, so the protocol (owner liability + floor reserve) is never
 *      under-collected. The 10 bps platform slice and the total both ceil with the SAME denominator,
 *      and `project = total - platform`, so `platform + project ≡ total`; the hook's realized
 *      ERC-6909 claim balance therefore always equals the recorded liabilities (solvent by
 *      construction), and `project == 0` exactly when `effective == 1000`.
 *
 *      Enabled callbacks (permission mask = 0x10cc): afterInitialize, beforeSwap, afterSwap,
 *      beforeSwapReturnDelta, afterSwapReturnDelta.
 */
contract AntifragileFloorHook is BaseHook {
    using CurrencySettler for Currency;
    using SafeCast for uint256;

    /* ------------------------------------------------------------------ */
    /*                          Immutable config                          */
    /* ------------------------------------------------------------------ */

    /// @notice Immutable owner. Only this address may claim the platform liability. No setter exists.
    address public constant OWNER = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;

    /// @dev Platform rate in hundredths-of-a-bip (1000 = 10 bps). The owner's fixed slice.
    uint256 internal constant PLATFORM_RATE = 1000;

    /// @dev Denominator for hundredths-of-a-bip rates: `amount * rate / 1_000_000`.
    uint256 internal constant RATE_DENOM = 1_000_000;

    /// @notice Total fee, in basis points, the hook is configured with (immutable ctor arg).
    uint16 public immutable feeTotalBps;

    /// @notice Effective total rate in hundredths-of-a-bip = max(feeTotalBps*100, 1000).
    uint256 public immutable effectiveRate;

    /// @notice The pool's quote asset. Fees are always measured and collected in this currency.
    Currency public immutable quoteCurrency;

    /* ------------------------------------------------------------------ */
    /*                          Bound-pool state                          */
    /* ------------------------------------------------------------------ */

    /// @notice The non-quote ("token") side of the bound canonical pool. Set in {_afterInitialize}.
    Currency public tknCurrency;

    /// @notice The bound canonical pool id. Set once in {_afterInitialize}.
    PoolId public poolId;

    /// @dev True once a canonical pool has been bound.
    bool private _bound;

    /* ------------------------------------------------------------------ */
    /*                        Liability + reserve                         */
    /* ------------------------------------------------------------------ */

    /// @notice Owner-claimable platform liability (10 bps), pool- and currency-scoped. No netting.
    mapping(PoolId => mapping(Currency => uint256)) public programmableFeeOwed;

    /// @notice The floor reserve: accumulated project portion (effective-1000), as quote ERC-6909 claims.
    uint256 public reserveQuote;

    /* ------------------------------------------------------------------ */
    /*                              Events                                 */
    /* ------------------------------------------------------------------ */

    /// @notice Emitted whenever the mandatory fee is collected on a swap.
    event ProgrammableFeeCollected(
        PoolId indexed poolId, Currency indexed currency, uint256 platformAmount, uint256 projectAmount
    );

    /// @notice Emitted when the owner claims the platform liability to a chosen destination.
    event ProgrammableFeeClaimed(
        PoolId indexed poolId, Currency indexed currency, address indexed destination, uint256 amount
    );

    /* ------------------------------------------------------------------ */
    /*                              Errors                                 */
    /* ------------------------------------------------------------------ */

    /// @dev The initialized pool does not contain {quoteCurrency}.
    error NotQuotePool();
    /// @dev A canonical pool is already bound to this hook.
    error PoolAlreadyBound();
    /// @dev Caller is not the immutable {OWNER}.
    error NotOwner();
    /// @dev Claim destination is the zero address.
    error InvalidDestination();

    /**
     * @param _pm The Uniswap v4 PoolManager singleton.
     * @param _feeTotalBps The configured total fee in basis points.
     * @param _quote The pool's quote currency (the asset fees are measured/collected in).
     */
    constructor(IPoolManager _pm, uint16 _feeTotalBps, Currency _quote) BaseHook(_pm) {
        feeTotalBps = _feeTotalBps;
        uint256 selected = uint256(_feeTotalBps) * 100;
        effectiveRate = selected < PLATFORM_RATE ? PLATFORM_RATE : selected;
        quoteCurrency = _quote;
    }

    /* ------------------------------------------------------------------ */
    /*                            Permissions                             */
    /* ------------------------------------------------------------------ */

    /// @inheritdoc BaseHook
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

    /* ------------------------------------------------------------------ */
    /*                           Initialize                               */
    /* ------------------------------------------------------------------ */

    /**
     * @dev Binds the hook to its canonical pool. The pool MUST contain {quoteCurrency}; the other
     *      side is stored as {tknCurrency}. Binding happens exactly once.
     */
    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        override
        returns (bytes4)
    {
        Currency q = quoteCurrency;
        if (!(key.currency0 == q) && !(key.currency1 == q)) revert NotQuotePool();
        if (_bound) revert PoolAlreadyBound();

        _bound = true;
        tknCurrency = key.currency0 == q ? key.currency1 : key.currency0;
        poolId = key.toId();
        return IHooks.afterInitialize.selector;
    }

    /* ------------------------------------------------------------------ */
    /*                        Swap fee collection                         */
    /* ------------------------------------------------------------------ */

    /**
     * @dev BEFORE-quadrant collection: when the quote currency is the swap's SPECIFIED currency, its
     *      amount is known pre-swap (`|amountSpecified|`). We mint the total charge as quote ERC-6909
     *      claims and return it as a positive `beforeSwapReturnDelta` on the specified currency; v4
     *      then carves it out of the swap (exact-input: less is swapped; exact-output: extra is
     *      produced for the hook). AFTER-quadrant swaps are handled in {_afterSwap}.
     */
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // collect BEFORE iff the quote currency is the specified currency of this swap
        bool specifiedTokenIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        bool quoteIsSpecified = (key.currency0 == quoteCurrency) == specifiedTokenIs0;
        if (!quoteIsSpecified) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, uint24(0));
        }

        uint256 grossQuote =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 total = _collect(key.toId(), grossQuote);

        // Positive specified delta => hook is credited `total` of the (quote) specified currency.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(total.toInt128(), int128(0)), uint24(0));
    }

    /**
     * @dev AFTER-quadrant collection: when the quote currency is the swap's UNSPECIFIED currency, its
     *      executed amount is only known post-swap. We read the ACTUAL executed quote amount from the
     *      swap `BalanceDelta`, mint the total charge as quote ERC-6909 claims, and return it as a
     *      positive `afterSwap` delta on the unspecified (quote) currency. BEFORE-quadrant swaps were
     *      already collected in {_beforeSwap} and are a no-op here.
     */
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        bool specifiedTokenIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        bool isQuote0 = key.currency0 == quoteCurrency;
        bool quoteIsSpecified = isQuote0 == specifiedTokenIs0;
        if (quoteIsSpecified) {
            return (IHooks.afterSwap.selector, int128(0)); // already collected in _beforeSwap
        }

        int128 quoteDelta = isQuote0 ? delta.amount0() : delta.amount1();
        uint256 grossQuote = quoteDelta < 0 ? uint256(int256(-quoteDelta)) : uint256(int256(quoteDelta));
        uint256 total = _collect(key.toId(), grossQuote);

        return (IHooks.afterSwap.selector, total.toInt128());
    }

    /**
     * @dev Takes the whole hook-owned charge as quote ERC-6909 claims and records the split:
     *      the fixed 10 bps platform slice into the owner-claimable liability, the remainder into the
     *      floor reserve. Returns `total` for the caller to return as its (before/after) swap delta.
     */
    function _collect(PoolId id, uint256 grossQuote) internal returns (uint256 total) {
        uint256 platform;
        uint256 project;
        (total, platform, project) = _quoteFee(grossQuote);
        if (total == 0) return 0;

        // Mint `total` of the quote currency to this hook as ERC-6909 claims (offsets the swap delta).
        quoteCurrency.take(poolManager, address(this), total, true);

        programmableFeeOwed[id][quoteCurrency] += platform;
        reserveQuote += project;
        emit ProgrammableFeeCollected(id, quoteCurrency, platform, project);
    }

    /* ------------------------------------------------------------------ */
    /*                          Owner claim                               */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Owner-only. Pays `destination` the platform liability owed for `(poolId, currency)`
     *         from this hook's ERC-6909 quote claims, and zeroes the liability.
     * @dev The destination is chosen per call; there is no stored mutable recipient. Only {OWNER}
     *      may call. The project reserve is never touched here.
     */
    function claimProgrammableFee(PoolId _poolId, Currency currency, address destination) external {
        if (msg.sender != OWNER) revert NotOwner();
        if (destination == address(0)) revert InvalidDestination();

        uint256 amount = programmableFeeOwed[_poolId][currency];
        programmableFeeOwed[_poolId][currency] = 0;

        if (amount > 0) {
            // Unlock the PoolManager so we can burn the hook's ERC-6909 claims and pay out the underlying.
            poolManager.unlock(abi.encode(currency, destination, amount));
        }
        emit ProgrammableFeeClaimed(_poolId, currency, destination, amount);
    }

    /**
     * @dev PoolManager unlock callback used by {claimProgrammableFee} to burn the hook's ERC-6909
     *      claims and pay out the underlying tokens to the destination.
     */
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Currency currency, address destination, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        currency.settle(poolManager, address(this), amount, true); // burn ERC-6909 -> +amount hook delta
        currency.take(poolManager, destination, amount, false); //     ERC-20 out -> -amount hook delta (nets to 0)
        return bytes("");
    }

    /* ------------------------------------------------------------------ */
    /*                          Fee math                                  */
    /* ------------------------------------------------------------------ */

    /**
     * @dev Splits a gross quote amount into the total hook charge and its platform/project portions.
     *      All amounts ceil (protocol favor). `project = total - platform` keeps the split exact.
     */
    function _quoteFee(uint256 grossQuote)
        internal
        view
        returns (uint256 total, uint256 platform, uint256 project)
    {
        total = _ceilDiv(grossQuote * effectiveRate, RATE_DENOM);
        platform = _ceilDiv(grossQuote * PLATFORM_RATE, RATE_DENOM);
        project = total - platform; // effective >= PLATFORM_RATE => total >= platform (ceil is monotonic)
    }

    /// @dev Ceil division: ceil(a / b). Returns 0 when a == 0.
    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
