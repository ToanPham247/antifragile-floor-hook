// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FloorMath} from "./lib/FloorMath.sol";

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
 * @notice Uniswap v4 hook implementing (a) the mandatory Programmable volume-fee policy
 *         `programmable-volume-fee-v1` and (b) a self-funded, monotonic price FLOOR that sellers can
 *         always redeem against, for the Antifragile Floor.
 *
 * @dev FLOOR SUMMARY ("top-up to floor" — Design A, decoupled from the fee; see docs/FLOOR.md):
 *
 *      The project slice of the fee accrues into `reserveQuote`. The floor price is
 *      `floorPrice(reserveQuote, backedSupply)` (QUOTE-per-TKN, WAD), where `backedSupply` is the TKN's
 *      circulating `totalSupply()`. `floorHigh` is a MONOTONIC high-water mark of that price. On an
 *      EXACT-INPUT SELL (TKN in, QUOTE out) the AMM executes the WHOLE swap first (the core AMM leg is
 *      never zero — this is NOT a custom curve); then {_afterSwap} subsidises the seller from the
 *      reserve up to the floor: `topUp = min(max(floorHigh*tknIn/1e18 - ammQuoteOut, 0), reserveQuote)`.
 *      The seller receives `ammQuoteOut - fee + topUp`. The top-up is a RESERVE-FUNDED SUBSIDY, not swap
 *      volume: the fee is still charged ONLY on the executed `ammQuoteOut`. When the reserve cannot
 *      reach the floor the sell is PARTIALLY honored (whole reserve paid, `reserveQuote -> 0`), never
 *      reverted. Buys, exact-output sells, and a zero floor/reserve get no top-up. The floor NEVER pays
 *      more QUOTE than the reserve holds, so the hook is solvent by construction (see {_afterSwap}).
 *
 *      POLICY SUMMARY (see docs/ for the full spec):
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
    ///         Also the sole funding source for floor top-ups (see {_afterSwap}). Every unit of
    ///         `reserveQuote` is backed 1:1 by this hook's ERC-6909 quote-claim balance.
    uint256 public reserveQuote;

    /// @notice Monotonic (never-decreasing) floor price high-water mark, QUOTE-per-TKN, WAD-scaled.
    /// @dev After every swap `floorHigh = max(floorHigh, floorPrice(reserveQuote, backedSupply))`.
    ///      It is the ENFORCED top-up target; the actual payout is ALWAYS additionally capped by the
    ///      available `reserveQuote` (the floor never promises more QUOTE than the reserve holds).
    ///      `backedSupply` is the TKN's circulating supply = `IERC20(tknCurrency).totalSupply()`.
    uint256 public floorHigh;

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

    /// @notice Emitted when the monotonic floor high-water mark increases.
    event FloorRatcheted(PoolId indexed poolId, uint256 floorHigh);

    /// @notice Emitted when an exact-input sell is topped up from the reserve toward the floor.
    /// @param swapper The swap initiator forwarded by the PoolManager (typically a router, not the EOA).
    /// @param tknIn The TKN amount offered by the sell (`|amountSpecified|`).
    /// @param topUp The QUOTE paid to the seller from `reserveQuote` on top of the AMM output.
    /// @param floorHigh The enforced floor target at the time of the top-up.
    event FloorToppedUp(
        PoolId indexed poolId, address indexed swapper, uint256 tknIn, uint256 topUp, uint256 floorHigh
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
     * @dev AFTER-quadrant fee collection PLUS the self-funded floor top-up (Design A — decoupled from
     *      the fee, no custom curve).
     *
     *      1. FEE (unchanged): when the quote currency is the swap's UNSPECIFIED currency its executed
     *         amount is only known post-swap. We read the ACTUAL executed quote from the swap
     *         `BalanceDelta`, mint the total charge as quote ERC-6909 claims, and hold it as a positive
     *         `afterSwap` delta (`feeDelta`) on the unspecified (quote) currency. BEFORE-quadrant swaps
     *         were already collected in {_beforeSwap} (`feeDelta == 0` here). The fee basis is ALWAYS the
     *         executed quote volume — the top-up below never changes it.
     *
     *      2. RATCHET (every swap): `floorHigh = max(floorHigh, floorPrice(reserveQuote, backedSupply))`.
     *
     *      3. TOP-UP (exact-input SELL only — TKN in, QUOTE out, `amountSpecified < 0`, quote unspecified):
     *         the AMM already executed the WHOLE swap (`ammQuoteOut` = the executed quote output), so the
     *         core AMM leg is never zero. We then subsidise the seller from `reserveQuote` up to the
     *         floor: `targetGross = floorHigh * tknIn / 1e18`,
     *         `topUp = ammQuoteOut >= targetGross ? 0 : min(targetGross - ammQuoteOut, reserveQuote)`.
     *         The top-up is a RESERVE-FUNDED SUBSIDY, not swap volume — it is NOT part of the fee basis.
     *         It is paid by burning `topUp` of the hook's quote ERC-6909 claims (`reserveQuote -= topUp`)
     *         and returning it as a NEGATIVE afterSwap delta, netted with the fee:
     *         `net = feeDelta - topUp`. The seller therefore receives `ammQuoteOut - fee + topUp`.
     *
     *      SOLVENCY (hard invariant): `topUp <= reserveQuote <= (quote ERC-6909 balance)`, and the fee
     *      mint (`+total`) minus the top-up burn (`-topUp`) exactly matches the change in
     *      `reserveQuote + Σ programmableFeeOwed`, so the hook's realized ERC-6909 quote-claim balance
     *      always equals `reserveQuote + platform liabilities`. The hook can never pay out more than it
     *      holds; a reserve too small to reach the floor is PARTIALLY honored (seller gets the whole
     *      reserve, `reserveQuote -> 0`), never reverted.
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Quote is the UNSPECIFIED (after-quadrant) currency iff isQuote0 != specifiedTokenIs0.
        // Scoped so the intermediate booleans don't stay live across the rest of the frame.
        bool quoteIsUnspecified;
        {
            bool specifiedTokenIs0 = (params.amountSpecified < 0) == params.zeroForOne;
            quoteIsUnspecified = (key.currency0 == quoteCurrency) != specifiedTokenIs0;
        }

        // ---- 1. Fee (after-quadrant only; before-quadrant already collected in _beforeSwap) ----
        int128 feeDelta = 0;
        uint256 ammQuoteOut = 0;
        if (quoteIsUnspecified) {
            int128 quoteDelta = (key.currency0 == quoteCurrency) ? delta.amount0() : delta.amount1();
            uint256 grossQuote = quoteDelta < 0 ? uint256(int256(-quoteDelta)) : uint256(int256(quoteDelta));
            feeDelta = _collect(poolId, grossQuote).toInt128();
            // For a SELL the quote is produced (positive delta) => that positive amount is ammQuoteOut.
            ammQuoteOut = quoteDelta > 0 ? uint256(int256(quoteDelta)) : 0;
        }

        // ---- 2. Ratchet the monotonic floor from the (post-fee) reserve ----
        uint256 floorNow = FloorMath.ratchet(floorHigh, FloorMath.floorPrice(reserveQuote, _backedSupply()));
        if (floorNow != floorHigh) {
            floorHigh = floorNow;
            emit FloorRatcheted(poolId, floorNow);
        }

        // ---- 3. Top-up: exact-input SELL only (TKN in, QUOTE out, amountSpecified < 0) ----
        uint256 topUp = 0;
        if (quoteIsUnspecified && params.amountSpecified < 0) {
            topUp = _topUpToFloor(sender, uint256(-params.amountSpecified), ammQuoteOut, floorNow);
        }

        // Net unspecified-quote delta: fee is taken (+), top-up is paid out (-).
        return (IHooks.afterSwap.selector, feeDelta - topUp.toInt128());
    }

    /**
     * @dev Pays the seller a reserve-funded subsidy up to the floor, capped by `reserveQuote` (partial
     *      honor). Burns `topUp` quote ERC-6909 claims so the returned negative net delta reaches the
     *      seller; `topUp <= reserveQuote <= balance` keeps the burn covered and the hook solvent.
     *      Split out of {_afterSwap} to keep that frame within the EVM's 16-slot stack limit.
     */
    function _topUpToFloor(address sender, uint256 tknIn, uint256 ammQuoteOut, uint256 floorNow)
        internal
        returns (uint256 topUp)
    {
        if (floorNow == 0) return 0;
        uint256 reserve = reserveQuote;
        if (reserve == 0) return 0;

        uint256 targetGross = (floorNow * tknIn) / 1e18; // floorHigh is WAD-scaled QUOTE-per-TKN
        if (ammQuoteOut >= targetGross) return 0;

        uint256 deficit = targetGross - ammQuoteOut;
        topUp = deficit < reserve ? deficit : reserve; // partial honor: never more than the reserve
        reserveQuote = reserve - topUp;
        quoteCurrency.settle(poolManager, address(this), topUp, true); // burn claims -> +topUp hook delta
        emit FloorToppedUp(poolId, sender, tknIn, topUp, floorNow);
    }

    /**
     * @dev The TKN circulating supply that backs the floor. We use the ERC20 `totalSupply()` of the
     *      token side (documented choice: circulating == totalSupply for a token with no separate
     *      escrow). A larger backed supply spreads the same reserve across more tokens => a lower floor.
     */
    function _backedSupply() internal view returns (uint256) {
        return IERC20(Currency.unwrap(tknCurrency)).totalSupply();
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
