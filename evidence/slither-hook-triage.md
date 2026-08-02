# Slither triage — AntifragileFloorHook (final code)

- **Tool:** Slither 0.11.6 (crytic-compile via `forge`)
- **Command:** `slither . --foundry-compile-all --json .tmp/slither.json`
- **Compiled:** 130 contracts, 102 detectors, **1407** total detector results.
- **Review target:** `src/AntifragileFloorHook.sol` + `src/lib/FloorMath.sol`.
- **Commit:** `b1fa1fbce647273643f404bc920a0ee1c134960d` (88-test final code, incl. the immutable `backedSupplySnapshot` hardening).

The detector count grew from the earlier 1253 (commit `cd2109a`) to 1407 because the audit suite (`test/audit/*`) added mock/token-model contracts to the compilation unit (130 vs 120 contracts). The dispositions of the review-target findings are unchanged; only line numbers moved after the `backedSupplySnapshot` hardening.

## Scope of the noise vs. the hook

| Bucket (by primary element) | Results | In scope? |
|---|---:|---|
| All compiled contracts | 1407 | — |
| `node_modules/@uniswap` (v4-core incl. its `src/test` + `lib/forge-std`) | 979 | No (third-party) |
| `test/` (harness, invariant handlers, audit mocks) | 407 | No (test-only) |
| `node_modules/@openzeppelin` | 10 | No (third-party) |
| **`src/` (the hook — review target)** | **11 primary + 1 shared `pragma` = 12** | **Yes — triaged below** |

Across **all** 130 contracts there are 27 High and 149 Medium results; **exactly one** of those 176 touches the review target (`unused-return` below). Every other High/Medium lives in the pinned Uniswap/OpenZeppelin dependencies or the test scaffolding, which are not the review target.

## Disposition of every finding that references the hook source (12)

Legend: **TP** = true-positive bug · **FP** = false-positive (safe) · **INFO** = informational/cosmetic.

| # | Detector | Impact | Location (final code) | Disposition | One-line rationale |
|---|---|---|---|---|---|
| 1 | `unused-return` | Medium | `claimProgrammableFee` ignores `poolManager.unlock(...)` return (L453) | **FP** | `unlockCallback` returns empty `bytes("")` by design; there is no meaningful value to consume. Burn+take settlement happens inside the callback and any failure reverts the whole tx atomically. |
| 2 | `reentrancy-benign` | Low | `_afterSwap` (L327-377): `floorHigh` written after `_collect` external calls | **FP** | The only external calls are to the trusted v4 PoolManager (`take`/`mint`/`settle` via CurrencySettler), executed inside the PoolManager's own lock; no untrusted callee, so no reentrancy vector. Slither itself rates it "benign". |
| 3 | `reentrancy-benign` | Low | `_collect` (L420-432): `programmableFeeOwed`/`reserveQuote` written after `quoteCurrency.take` (L427) | **FP** | `take(..., claims=true)` only mints the hook's own ERC-6909 claim inside the PoolManager lock — no external/untrusted call to re-enter through. |
| 4 | `reentrancy-events` | Low | `_topUpToFloor` (L385-401): `FloorToppedUp` after `settle` | **FP** | `reserveQuote` is decremented (L398) **before** the `settle` burn (L399); the event (L400) is last. CEI respected; event-ordering only. |
| 5 | `reentrancy-events` | Low | `_collect` (L420-432): `ProgrammableFeeCollected` (L431) after `take` (L427) | **FP** | Event emitted after a PoolManager-only ERC-6909 mint; no untrusted reentrancy; ordering immaterial. |
| 6 | `reentrancy-events` | Low | `claimProgrammableFee` (L444-456): `ProgrammableFeeClaimed` (L455) after `unlock` (L453) | **FP** | Checks-Effects-Interactions respected: the liability is zeroed (L449) **before** `unlock` (L453), so a re-entry finds `amount = 0` — no double-claim. Event ordering only. |
| 7 | `reentrancy-events` | Low | `_afterSwap` (L327-377): `FloorRatcheted` after `_collect` | **FP** | Trusted PoolManager inside the swap lock; ratchet write + event ordering has no security impact. |
| 8 | `reentrancy-events` | Low | `_afterSwap` (L327-377): `FloorToppedUp` after `_collect`+`_topUpToFloor` | **FP** | Same trusted-PoolManager-in-lock argument; event-ordering only, no state corruption possible. |
| 9 | `pragma` | Info | 11 Solidity versions across the dependency tree | **INFO/FP** | The review-target source pins an **exact** `pragma solidity 0.8.26` (no caret/range). The version spread is entirely inside third-party dependency interfaces. |
| 10 | `missing-inheritance` | Info | `AntifragileFloorHook` "should inherit `IUnlockCallback`" | **INFO** | Cosmetic: the contract implements `unlockCallback(bytes) external returns (bytes memory)` with the exact `IUnlockCallback` signature and `onlyPoolManager` gating; PoolManager dispatches by selector. Not a bug. (Left as-is to avoid touching audited source for a cosmetic change.) |
| 11 | `naming-convention` | Info | Parameter `_poolId` (L444) "not in mixedCase" | **INFO/FP** | The leading underscore is intentional — it avoids shadowing the `poolId` **state variable** in `claimProgrammableFee`. |
| 12 | `unimplemented-functions` | Info | "does not implement `getHookPermissions()`" | **FP** | Slither miscount: `getHookPermissions()` **is** implemented as a `public pure override` at L216-233. The abstract `BaseHook` declaration confuses the detector. |

## Conclusion

**No true-positive bug in the hook.** All 12 review-target findings are false-positives or informational, each with a documented safe rationale. The two structural safety properties Slither's reentrancy detectors probe are already enforced by design and by tests:

- **Every hook entrypoint is `onlyPoolManager`** and all external calls target the trusted PoolManager inside its own lock (`test_09_entrypointsAreOnlyPoolManager`, `test_06_hookEntrypointsAreOnlyPoolManager`, plus `ReentrancyDeeper.*`).
- **Checks-Effects-Interactions** is respected in both value-moving paths (`claimProgrammableFee` zeroes the liability at L449 before `unlock` at L453; `_topUpToFloor` decrements `reserveQuote` at L398 before `settle` at L399), and the hard solvency invariant `balance == reserveQuote + Σ programmableFeeOwed` holds after every swap and claim (`testFuzz_08_solvencyInvariant`, the invariant suites, and the mainnet-fork test).

No STOP condition: there is nothing to fix in the hook from this static-analysis pass.
