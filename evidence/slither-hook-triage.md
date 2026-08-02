# Slither triage — AntifragileFloorHook

- **Tool:** Slither 0.11.6 (crytic-compile via `forge`)
- **Command:** `slither . --foundry-compile-all --json .tmp/slither-report.json`
- **Compiled:** 120 contracts, 102 detectors, **1253** total detector results.
- **Review target:** `src/AntifragileFloorHook.sol` + `src/lib/FloorMath.sol`.
- **Commit:** `cd2109aeb0f7bc3c99b32225c171c1e5fd868330`

## Scope of the noise vs. the hook

| Bucket | Results | In scope? |
|---|---:|---|
| All compiled contracts | 1253 | — |
| `node_modules/@uniswap` (v4-core, v4-periphery, forge-std, solmate) | 917 | No (third-party) |
| `test/` (harness, invariant handlers, mocks) | 315 | No (test-only) |
| `node_modules/@openzeppelin` | 10 | No (third-party) |
| **`src/` (the hook — review target)** | **12** (11 primary + 1 shared) | **Yes — triaged below** |

Across **all** 120 contracts there are 26 High and 132 Medium results; **exactly one** of those 158 touches `src/` (the `unused-return` below). Every other High/Medium lives in the pinned Uniswap/OpenZeppelin dependencies or the test scaffolding, which are not the review target.

## Disposition of every finding that references the hook source (12)

Legend: **TP** = true-positive bug · **FP** = false-positive (safe) · **INFO** = informational/cosmetic.

| # | Detector | Impact | Location | Disposition | One-line rationale |
|---|---|---|---|---|---|
| 1 | `unused-return` | Medium | `claimProgrammableFee` ignores `poolManager.unlock(...)` return (L430) | **FP** | `unlockCallback` returns empty `bytes("")` by design; there is no meaningful value to consume. The settlement (burn+take) happens inside the callback and any failure reverts the whole tx atomically. |
| 2 | `reentrancy-benign` | Low | `_afterSwap`: `floorHigh` written after `_collect` external calls (L344) | **FP** | The only external calls are to the trusted v4 PoolManager (`mint`/`take` via CurrencySettler), executed inside the PoolManager's own lock; no untrusted callee, so no reentrancy vector. Slither itself rates it "benign". |
| 3 | `reentrancy-benign` | Low | `_collect`: `programmableFeeOwed`/`reserveQuote` written after `quoteCurrency.take` (L406–407) | **FP** | `take(..., claims=true)` only mints the hook's own ERC-6909 claim inside the PoolManager lock — no external/untrusted call to re-enter through. |
| 4 | `reentrancy-events` | Low | `claimProgrammableFee`: `ProgrammableFeeClaimed` after `unlock` (L432) | **FP** | Checks-Effects-Interactions is respected: the liability is zeroed (L426) **before** `unlock` (L430), so a re-entry finds `amount = 0` — no double-claim. Event ordering only. |
| 5 | `reentrancy-events` | Low | `_afterSwap`: `FloorToppedUp` after `_collect`+`_topUpToFloor` (via L352) | **FP** | Same trusted-PoolManager-in-lock argument; event-ordering only, no state corruption possible. |
| 6 | `reentrancy-events` | Low | `_collect`: `ProgrammableFeeCollected` after `take` (L408) | **FP** | Event emitted after a PoolManager-only ERC-6909 mint; no untrusted reentrancy; ordering immaterial. |
| 7 | `reentrancy-events` | Low | `_topUpToFloor`: `FloorToppedUp` after `settle` (L380) | **FP** | `reserveQuote` is decremented (L378) **before** the `settle` burn (L379); the event (L380) is last. CEI respected; event-ordering only. |
| 8 | `reentrancy-events` | Low | `_afterSwap`: `FloorRatcheted` after `_collect` (L345) | **FP** | Trusted PoolManager inside the swap lock; ratchet write + event ordering has no security impact. |
| 9 | `pragma` | Info | 11 Solidity versions across the dependency tree | **INFO/FP** | The review-target source pins an **exact** `pragma solidity 0.8.26` (no caret/range). The version spread is entirely inside third-party dependency interfaces. |
| 10 | `missing-inheritance` | Info | `AntifragileFloorHook` "should inherit `IUnlockCallback`" | **INFO** | Cosmetic: the contract implements `unlockCallback(bytes) external returns (bytes memory)` with the exact `IUnlockCallback` signature and `onlyPoolManager` gating; PoolManager dispatches by selector. Not a bug. (Left as-is to avoid touching audited source for a cosmetic change.) |
| 11 | `naming-convention` | Info | Parameter `_poolId` "not in mixedCase" | **INFO/FP** | The leading underscore is intentional — it avoids shadowing the `poolId` **state variable** in `claimProgrammableFee`. |
| 12 | `unimplemented-functions` | Info | "does not implement `getHookPermissions()`" | **FP** | Slither miscount: `getHookPermissions()` **is** implemented as a `public pure override` at L203–220. The abstract `BaseHook` declaration confuses the detector. |

## Conclusion

**No true-positive bug in the hook.** All 12 review-target findings are false-positives or informational, each with a documented safe rationale. The two structural safety properties Slither's reentrancy detectors probe are already enforced by design and by tests:

- **Every hook entrypoint is `onlyPoolManager`** and all external calls target the trusted PoolManager inside its own lock (`test_09_entrypointsAreOnlyPoolManager`, `test_06_hookEntrypointsAreOnlyPoolManager`).
- **Checks-Effects-Interactions** is respected in both value-moving paths (`claimProgrammableFee` zeroes the liability before `unlock`; `_topUpToFloor` decrements `reserveQuote` before `settle`), and the hard solvency invariant `balance == reserveQuote + Σ programmableFeeOwed` holds after every swap and claim (`testFuzz_08_solvencyInvariant`, the invariant suites, and the mainnet-fork test).

No STOP condition: there is nothing to fix in the hook from this static-analysis pass.
