// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AuditBase} from "./AuditBase.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {AntifragileFloorHook} from "../../src/AntifragileFloorHook.sol";

/**
 * @notice Mints ERC-6909 quote claims directly to an arbitrary address (e.g. the hook) inside a
 *         PoolManager unlock — the only way to "donate" claims and inflate the hook's raw claim balance
 *         above its internal accounting. Used to prove such a donation is inert and unstealable.
 */
contract ClaimDonor {
    using CurrencySettler for Currency;

    IPoolManager internal immutable mgr;

    constructor(IPoolManager m) {
        mgr = m;
    }

    function donate(Currency c, address to, uint256 amt) external {
        mgr.unlock(abi.encode(c, to, amt));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(mgr), "only mgr");
        (Currency c, address to, uint256 amt) = abi.decode(data, (Currency, address, uint256));
        c.settle(mgr, address(this), amt, false); // pull ERC20 in from this -> +amt delta
        c.take(mgr, to, amt, true); //                mint `amt` claims to `to` -> -amt delta (nets 0)
        return bytes("");
    }
}

/**
 * @title FeeBypassAndAccounting
 * @notice AUDIT — Vector 2 (fee bypass / theft) + Vector 3 (accounting robustness).
 *
 *   (1) FEE FRAGMENTATION: splitting a swap into many tiny swaps can never UNDER-charge the mandatory
 *       fee — each ceils independently, so fragmentation only ever pays MORE. No rounding bypass exists.
 *
 *   (2) ERC-6909 DONATION: anyone can mint quote claims to the hook, inflating its raw claim balance above
 *       `reserveQuote + owed`. This is INERT: it does not raise `reserveQuote`, does not raise the floor
 *       (the ratchet reads `reserveQuote`, never the balance), and is not withdrawable by anyone (no path
 *       pays beyond `reserveQuote`/`owed`). The strict solvency EQUALITY becomes a `>=` — a harmless
 *       over-collateralization, never an under-collateralization.
 */
contract FeeBypassAndAccounting is AuditBase {
    function setUp() public {
        _setUpManager();
    }

    /* ================================================================== */
    /*  Fragmenting a swap into tiny pieces never under-charges the fee.     */
    /* ================================================================== */

    function test_fragmentation_neverUndercharges() public {
        _mkTokens(3000e18, true); // quote = currency0
        AntifragileFloorHook h = _deployHook(3000); // effective 30%
        (PoolKey memory key, PoolId id) = _init(h);

        uint256 eff = h.effectiveRate();
        uint256 grossPer = 7; // wei; a size where ceil bites hard
        uint256 n = 20;

        uint256 feeBefore = _quoteBal(h);
        for (uint256 i = 0; i < n; i++) {
            uint256 stepBefore = _quoteBal(h);
            // before-quadrant quote-in exact-input (quote=currency0, zeroForOne) => gross == |amt| == 7 wei
            swapRouter.swap(
                key,
                SwapParams({zeroForOne: true, amountSpecified: -int256(grossPer), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ZERO_BYTES
            );
            // every tiny swap charges a strictly positive ceil fee (never rounds to zero)
            assertEq(_quoteBal(h) - stepBefore, _ceilDiv(grossPer * eff, RATE_DENOM), "per-swap fee not ceil-exact");
            assertGt(_quoteBal(h) - stepBefore, 0, "tiny swap dodged the fee");
        }
        uint256 loopFee = _quoteBal(h) - feeBefore;

        // Fragmentation pays at least (here strictly more than) the fee on the aggregate volume.
        uint256 aggFee = _ceilDiv(n * grossPer * eff, RATE_DENOM);
        assertGe(loopFee, aggFee, "fragmentation under-charged vs the aggregate");
        assertEq(loopFee, n * _ceilDiv(grossPer * eff, RATE_DENOM), "loop fee != sum of per-swap ceils");
        assertGt(loopFee, aggFee, "ceil should make fragmentation strictly costlier");
        _assertSolvent(h, id);
    }

    /* ================================================================== */
    /*  ERC-6909 donation to the hook is inert and unstealable.             */
    /* ================================================================== */

    function test_erc6909Donation_inert_notStealable() public {
        _mkTokens(3000e18, false);
        AntifragileFloorHook h = _deployHook(3000);
        (PoolKey memory key, PoolId id) = _init(h);
        _seedReserve(key, 1000e18);

        uint256 reserveBefore = h.reserveQuote();
        uint256 floorBefore = h.floorHigh();
        uint256 owedBefore = h.programmableFeeOwed(id, quote);

        // Donate a large slug of quote CLAIMS straight to the hook.
        uint256 donation = 500e18;
        ClaimDonor donor = new ClaimDonor(IPoolManager(address(manager)));
        MockERC20(Currency.unwrap(quote)).mint(address(donor), donation);
        vm.prank(address(donor));
        MockERC20(Currency.unwrap(quote)).approve(address(manager), type(uint256).max);
        donor.donate(quote, address(h), donation);

        // Raw claim balance jumped by the donation, but INTERNAL accounting is unmoved.
        assertEq(_quoteBal(h), reserveBefore + owedBefore + donation, "donation not reflected in raw claims");
        assertEq(h.reserveQuote(), reserveBefore, "donation must NOT raise reserveQuote");
        assertEq(h.floorHigh(), floorBefore, "donation must NOT raise the floor");
        // solvency is now an over-collateralized inequality, never under-collateralized.
        assertGe(_quoteBal(h), h.reserveQuote() + h.programmableFeeOwed(id, quote), "under-collateralized after donation");

        // The floor ratchet still reads reserveQuote (not the inflated balance): a buy ratchets from the
        // ACCOUNTED reserve, proving the donation can't be laundered into a higher floor.
        _swap(h, key, id, false, -int256(10e18));
        assertEq(
            h.floorHigh(),
            _floorFromReserve(h),
            "floor ratcheted off the donated balance instead of reserveQuote"
        );

        // Now try to STEAL the donation: drain the reserve to zero with a below-floor sell. The top-up is
        // capped by reserveQuote (which excludes the donation), so the donated claims remain stuck.
        MockERC20(Currency.unwrap(tkn)).mint(address(this), 7000e18);
        _modLiq(key, -(FULL_LIQ - int256(1e18)));
        _swap(h, key, id, true, -int256(6000e18));
        assertEq(h.reserveQuote(), 0, "reserve should have been drained to 0");
        // The donation (minus nothing) is still trapped in the hook's claim balance; nobody extracted it.
        assertGe(_quoteBal(h), donation, "the donation leaked out via the floor drain");
        assertGe(_quoteBal(h), h.reserveQuote() + h.programmableFeeOwed(id, quote), "still fully backed");
    }

    /// @dev floorHigh candidate implied by the CURRENT accounted reserve. The denominator is the hook's
    ///      IMMUTABLE bind-time snapshot (never a live totalSupply()), matching the hardened floor path.
    function _floorFromReserve(AntifragileFloorHook h) internal view returns (uint256) {
        uint256 supply = h.backedSupplySnapshot();
        return supply == 0 ? 0 : (h.reserveQuote() * WAD) / supply;
    }
}
