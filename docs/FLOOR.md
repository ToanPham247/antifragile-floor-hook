# The Antifragile Floor — self-funded, monotonic price floor (Design A: "top-up to floor")

## What it is

Every sell into the pool is guaranteed a QUOTE-per-TKN price **no worse than a floor the protocol
funds itself**. The floor is not a promise on paper: it is backed 1:1 by a real reserve the hook
holds as ERC-6909 quote claims, it only ever ratchets **up**, and — critically — it never promises
more than the reserve actually holds. When a market dumps and the AMM prices a seller far below the
backing, the hook tops the seller up out of the reserve. This is the core, novel mechanism.

It is implemented entirely in `afterSwap` and is **decoupled from the mandatory fee** and **not a
custom curve**: the AMM executes the *whole* swap first (the core AMM leg is always the full swap,
never zero), and only *then* does the hook add a reserve-funded subsidy on top.

## The pieces

### 1. Reserve

`reserveQuote` is the floor's warchest. It is fed by the **project slice** of the Programmable
volume-fee (`effective − 10bps` of executed quote volume; see `docs/PROGRAMMABLE_FEE.md`). It is held
as this hook's ERC-6909 quote-claim balance inside the PoolManager. No external top-ups, no setter —
the reserve can only grow from real swap fees, and only shrink by paying sellers at the floor.

### 2. Floor price and the monotonic ratchet

```
floor      = FloorMath.floorPrice(reserveQuote, backedSupply)   // = reserveQuote * 1e18 / backedSupply  (QUOTE per TKN, WAD)
floorHigh  = FloorMath.ratchet(floorHigh, floor)                // = max(floorHigh, floor)   — after EVERY swap
```

* **`backedSupply` = `backedSupplySnapshot` — an IMMUTABLE snapshot of `totalSupply()` captured ONCE at
  `_afterInitialize` (bind time), NOT a live read.**
  At bind time the hook records `backedSupplySnapshot = IERC20(tknCurrency).totalSupply()` alongside
  `tknCurrency`/`poolId`, set-once (the `PoolAlreadyBound` guard prevents any re-init/re-set). The floor
  path then reads only this frozen value — the live `totalSupply()` call is removed from the floor
  entirely.

  **Why (security — closes audit finding 1.2).** A live `totalSupply()` let a malicious `burn-anyone` /
  negative-rebase TKN crater the supply mid-transaction, spiking `floorHigh = reserveQuote·1e18/supply`,
  then redeem an untouched bag against the illegitimate floor and over-extract the reserve. Freezing the
  denominator at bind time makes the floor **immune to every post-init supply change** (mint, burn,
  rebase, or even a reentrant/reverting `totalSupply()`), so that manipulation is impossible.

  **Solvency-safe in every case** (the top-up is *always* additionally capped by `reserveQuote`):
  - *Fixed-supply TKN (the canonical model):* snapshot == live — **no behavior change**; the floor value
    is meaningful and honest, exactly as before.
  - *Supply later inflates (mint):* the snapshot **understates** true supply → the floor is slightly
    higher → more top-up, but still reserve-capped → solvency holds.
  - *Supply later burns:* the snapshot **overstates** true supply → the floor is lower → strictly safer.

  This keeps the original **conservative** reading (treat the whole minted supply as "backed" so the
  floor is never overstated) while removing the live-supply attack surface. A token that escrows/locks
  part of supply still does not get a higher floor; we deliberately snapshot the full minted supply.

* **`floorHigh` is monotonic** (a high-water mark). It is the *enforced target*. Because we only ever
  `ratchet` (take the max), it can never decrease — not when a top-up drains the reserve, not when the
  token supply inflates, not on any swap direction. The *actual payout* is always additionally capped
  by the live `reserveQuote` (see partial honor). So `floorHigh` can legitimately sit **above** the
  current `floorPrice` after the reserve is drained or the supply is inflated; the guarantee it
  represents is then honored only as far as the reserve allows.

### 3. Top-up (exact-input sells only)

An **exact-input sell** is: TKN in, QUOTE out, `amountSpecified < 0`, and the quote is the swap's
*unspecified* (output) currency. This holds for **both token orderings** — the hook derives the sell
direction from `quoteCurrency` being `currency0` or `currency1`, so it works whether the quote is
token0 or token1.

```
tknIn        = executed TKN the pool received         // from the swap BalanceDelta TKN side — NOT |amountSpecified|
ammQuoteOut  = the quote the AMM actually produced    // from the swap BalanceDelta quote side (executed)
targetGross  = floorHigh * tknIn / 1e18
topUp        = ammQuoteOut >= targetGross ? 0 : min(targetGross - ammQuoteOut, reserveQuote)
```

If `topUp > 0` the hook burns `topUp` of its quote ERC-6909 claims (`reserveQuote -= topUp`) and pays
it to the seller as an additional `afterSwap` return-delta. **The seller receives
`ammQuoteOut − fee + topUp`.**

`tknIn` is the **executed** TKN the pool actually received on this swap — read from the swap
`BalanceDelta` (the TKN-side delta the swapper paid in), **not** the requested `|amountSpecified|`.
This is load-bearing when a swap **partially fills**: a tight `sqrtPriceLimitX96` can execute only a
sliver of the offered TKN, so `|amountSpecified|` may be far larger than the TKN the pool actually took
in. Sizing the subsidy on the *requested* amount would pay a floor top-up for TKN that was never
delivered — the critical reserve-drain closed by the security fix at `cd2109a`. Sizing it on the
executed `tknIn` makes the top-up match exactly what the seller actually sold; the payout is still
additionally capped by `reserveQuote`, so the floor can never be over-subsidised and solvency always
holds, even on a price-limited partial fill.

### 4. Fee vs. subsidy — the fee basis is unchanged

The mandatory fee is charged **only on `ammQuoteOut`** (the actual executed pool swap volume), exactly
as before the floor existed. The top-up is a **reserve-funded subsidy**, *not* swap volume, and is
never part of the fee basis. `test_10_feeBasisUnchangedByTopUp` proves this by reconstructing the
executed `ammQuoteOut` from the delta and asserting `fee == ceil(ammQuoteOut * effectiveRate / 1e6)`
(and that charging on the subsidised gross would have been strictly larger). The 13 `ProgrammableFee`
tests remain green **unchanged** — with the stock test currencies (`totalSupply = 2**255`) the floor
price rounds to 0, so `floorHigh` stays 0 and the top-up path is never taken there.

### 5. Combining the fee delta with the top-up delta

Both the fee and the top-up land on the **same** currency (the unspecified quote) in `afterSwap`, so
they net into a single `int128`:

```
net = feeDelta − topUp        // feeDelta = +fee (taken from the swapper), topUp = paid to the swapper
```

Settlement, per unit, in the PoolManager's delta accounting:

| step                                  | ERC-6909 op                              | hook currencyDelta |
|---------------------------------------|------------------------------------------|--------------------|
| fee `take(total, claims=true)`        | `mint(hook, total)`                      | `−total`           |
| top-up `settle(topUp, burn=true)`     | `burn(hook, topUp)`                      | `+topUp`           |
| `afterSwap` returns `net = total−topUp`| PoolManager accounts `+(total − topUp)` | `+(total − topUp)` |

Sum = `−total + topUp + (total − topUp) = 0` → the hook's own delta closes to zero, and the swapper's
quote output becomes `ammQuoteOut − (total − topUp) = ammQuoteOut − fee + topUp`. The hook's realized
ERC-6909 quote balance changes by exactly `total − topUp`, matching the change in
`reserveQuote (+project −topUp)` and `programmableFeeOwed (+platform)`.

## Partial honor — the disclosed failure mode

The floor **never promises more QUOTE than the reserve holds.** If `targetGross − ammQuoteOut` exceeds
`reserveQuote`, the hook pays out the **whole** reserve (`reserveQuote → 0`) and the seller receives
`ammQuoteOut + reserveQuote − fee`, *below* the floor. This is not a bug and never reverts — it is the
honest, disclosed limit of a self-funded floor.

Because `floorPrice = reserveQuote / backedSupply`, `targetGross = floorHigh * tknIn` can exceed the
reserve only when `floorHigh` sits **above the current floor price** — i.e. after the reserve has been
drained by a prior top-up, or after the TKN supply has inflated past what the reserve was ratcheted
against. `test_03_partialHonor_reserveExhausted` forces exactly this (mint extra TKN after the
ratchet, then sell more than the originally-backed supply) and asserts the whole reserve is paid, the
reserve lands on 0, and the hook stays solvent.

## Solvency — the hard invariant

At all times:

```
hook ERC-6909 quote-claim balance  ==  reserveQuote + Σ programmableFeeOwed[poolId][quote]
```

This is exact, not approximate, and holds after **every** swap and after an owner fee claim. It is
enforced by construction: the top-up is capped at `reserveQuote ≤ balance`, only `reserveQuote` is
decremented for a top-up (the platform liability is never touched), and the fee mint minus the top-up
burn equals the balance delta. `testFuzz_08_solvencyInvariant` runs random swap sequences plus a claim
and asserts the equality after each step, and that no normal swap ever reverts on the reserve math.

## Events

* `FloorRatcheted(poolId, floorHigh)` — emitted whenever the monotonic high-water mark increases.
* `FloorToppedUp(poolId, swapper, tknIn, topUp, floorHigh)` — emitted on every reserve-funded top-up.
  `swapper` is the swap initiator forwarded by the PoolManager (typically a router, not the EOA).

## Test map

| # | Test | Guarantee |
|---|------|-----------|
| 1 | `test_01_sellBelowFloor_toppedUp_quote1` | sell below floor is topped up to the floor (quote = currency1) |
| 6 | `test_06_sellBelowFloor_toppedUp_quote0` | same, with quote = currency0 (both orderings) |
| 2 | `test_02_smallSellAboveFloor_noTopUp` | tiny sell above floor uses the AMM only, no subsidy |
| 3 | `test_03_partialHonor_reserveExhausted` | reserve too small → whole reserve paid, `→ 0`, no revert |
| 4 | `test_04_floorHigh_monotonic` | `floorHigh` never decreases across drains + supply inflation |
| 5 | `test_05_buysNeverToppedUp` | buys (exact-in and exact-out) never top up |
| 7 | `test_07_exactOutputSell_noTopUp_noRevert` | exact-output sells get no top-up, no revert |
| 8 | `testFuzz_08_solvencyInvariant` | `balance == reserve + owed` after random swaps + a claim |
| 9 | `test_09_entrypointsAreOnlyPoolManager` | before/after/unlockCallback are PoolManager-gated |
| 10 | `test_10_feeBasisUnchangedByTopUp` | fee is charged on executed `ammQuoteOut`, never the subsidised gross |
