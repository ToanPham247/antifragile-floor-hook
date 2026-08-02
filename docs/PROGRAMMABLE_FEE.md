# Programmable volume-fee — `programmable-volume-fee-v1`

The mandatory hook-owned swap fee implemented by `src/AntifragileFloorHook.sol`. Judged on
security; this is the spec the implementation and `test/ProgrammableFee.t.sol` are held to.

## Rates

Rates are in **hundredths-of-a-bip**: `1000 = 10 bps = 0.10%`, denominator `1_000_000`.

| symbol      | value                                   |
| ----------- | --------------------------------------- |
| `selected`  | `feeTotalBps * 100`                     |
| `effective` | `max(selected, 1000)` (a 10 bps floor)  |
| `platform`  | `1000` — exactly 10 bps                 |
| `project`   | `effective - 1000`                      |

The split is **non-additive**: the 10 bps platform is carved OUT of the total, never added on
top — `platform + project == total`. Example (`feeTotalBps = 300`, i.e. 3%): `0.1% + 2.9% = 3.0%`,
never 3.1%.

## Basis

The fee is measured on the **executed gross quote-side volume**, in the pool's quote asset, on the
ACTUAL executed amount (post partial-fill), BEFORE deducting portions.

## Quadrant-dependent collection

`quoteCurrency` is an immutable constructor arg and may be either side of the pool. Collection uses
the v4 return-delta channel dictated by which side the quote is on:

| quote asset | zeroForOne exactIn | zeroForOne exactOut | oneForZero exactIn | oneForZero exactOut |
| ----------- | ------------------ | ------------------- | ------------------ | ------------------- |
| currency0   | before             | after               | after              | before              |
| currency1   | after              | before              | before             | after               |

- **before** — `beforeSwapReturnDelta`: quote is the swap's *specified* currency; its amount is known
  pre-swap (`|amountSpecified|`). The hook mints the charge as quote ERC-6909 claims and returns it as
  a positive specified delta; v4 carves it out of the swap.
- **after** — `afterSwap` return delta: quote is the swap's *unspecified* currency; its executed
  amount is read from the swap `BalanceDelta` post-swap.

The entire table reduces to one predicate: **collect BEFORE iff the quote currency is the swap's
specified currency, else collect AFTER** — see `_beforeSwap` / `_afterSwap`.

## Rounding — protocol favor

Fee amounts round **UP (ceil)**: a swap is charged at least the nominal rate, never less, so the
protocol (owner liability + floor reserve) is never under-collected. The total and the 10 bps platform
slice both ceil with the same denominator, and `project = total - platform`, so `platform + project ≡
total` and `project == 0` exactly when `effective == 1000`. The hook takes the whole charge as a single
ERC-6909 claim delta, so its realized claim balance always equals the recorded liabilities — solvent by
construction.

## Custody, owner & claims

- **Owner** is the immutable constant `0x4957f49620AFf3Adbbe8195a4f633E49cc93376c` — no setter.
- **platform** accrues as a claimable liability `programmableFeeOwed[poolId][currency]` (pool- and
  currency-scoped, no cross-pool netting). **project** accrues into `reserveQuote` (the floor reserve;
  ratchet/honor land in a later task). Both are held as this hook's ERC-6909 quote claims.
- `claimProgrammableFee(poolId, currency, destination)` — **owner-only**, pays `destination`
  (owner-selectable per claim) the owed platform amount via `CurrencySettler` (burn ERC-6909 → take
  underlying) inside a PoolManager unlock, then zeroes the liability. There is no stored mutable
  recipient; builder / project / anyone-else can never claim or mutate.
- **selfCallPolicy = same-pool-swap-forbidden**: the hook never initiates a swap on its own pool (it
  contains no `poolManager.swap` call); v4 additionally no-ops hook callbacks on self-calls, and all
  hook entry points are `onlyPoolManager`.

## Events

- `ProgrammableFeeCollected(poolId, currency, platformAmount, projectAmount)` on each collection.
- `ProgrammableFeeClaimed(poolId, currency, destination, amount)` on each owner claim.

Both reconcile exactly with balances/liabilities under the ceil rounding (see
`test_11_eventsReconcile`).
