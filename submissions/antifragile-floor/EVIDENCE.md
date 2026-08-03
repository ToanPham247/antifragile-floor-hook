# Evidence

Structured evidence for one exact submission revision. All results are **builder-declared, untrusted** local tool output on the final code (commit `b1fa1fbce647273643f404bc920a0ee1c134960d`, 88 tests). Nothing here is acceptance, an audit, deployment, verification, routing approval, or availability.

- **Compatibility report:** `compatibility-report.json` — `decision = PROTOTYPE_READY`, standard `1.3.0`, hook permission mask `0x10cc`, risk base `medium` / effective `high` / score 13.
- **Submission hash:** `sha256:dc928f5d5e60cb37f2522107cf9bae16ff5fd485d576f3d0ebb147eb27574079`.
- **Review-target hash:** bound in `review-target.json` and copied into `gate-status.json` and every completed gate-evidence record (closure method v10 deliberately excludes `gate-status.json` and `review-target.json` from its own file subject).
- **Toolchain:** `forge 1.7.1 (4072e48705 2026-05-08)`, `cast 1.7.1`, `slither 0.11.6`, `solc 0.8.26+commit.8a97fa7a` (cancun, optimizer runs=200, `bytecode_hash=none`, no viaIR).

## Gate evidence (all `completed`, real content hashes)

| Gate | Result | Command | Artifact | sha256 |
| --- | --- | --- | --- | --- |
| `format-build-size-warnings` | passed | `forge build --force --build-info` | `evidence/forge-build.txt` | `f2e0f7d2b2faa980b7615d4d6177a3e63a4e355ffbbc665529f9867c028d2620` |
| `format-build-size-warnings` | passed | `forge snapshot --no-match-path 'test/fork/*'` | `.gas-snapshot` | `06ba3416e19f32109a6c26c4015ce3031a8cb24a17888e8a5c1965710e1ed89b` |
| `unit-integration-fuzz-invariant-tests` | passed (85/85) | `forge test --no-match-path 'test/fork/*'` | `evidence/forge-test-local.txt` | `5aedfa1aea83c178b9fda21ab3187a14424da00d837d9d66c892ba7b1087260b` |
| `callback-authentication-and-permission-mask` | passed | `forge test --no-match-path 'test/fork/*'` | `evidence/forge-test-local.txt` | `5aedfa1aea83c178b9fda21ab3187a14424da00d837d9d66c892ba7b1087260b` |
| `static-analysis` | passed | `slither . --foundry-compile-all --json .tmp/slither.json` | `evidence/slither-hook-triage.md` | `95c4ed34bbb170362f45901e5dc0077de394abc3769ccc3b84ebfd1d74d4f5e6` |
| `static-analysis` | passed | `node -e '<extract src findings>'` | `evidence/slither-hook-findings.json` | `b9e21c44cd736768ca053c898a21b446d34d089820223f81a26c11d61fb67c16` |
| `mainnet-fork-pinned-and-head-smoke` | passed (3/3) | `MAINNET_RPC_URL=https://eth.drpc.org forge test --match-path 'test/fork/*' -vv` | `evidence/forge-test-fork.txt` | `9bef437069d7d63318277d4390b22f1c1cd8a6a880c4b2132eb3a733fb0861af` |
| `mainnet-fork-pinned-and-head-smoke` | passed | `cast codehash … --block 25666892 ; Sourcify v2 lookup` | `deployment-evidence.json` | `a2d92bb6884b91707619d5ac7039152a76735430ff3f9dcdabdd280271af9275` |

Each gate-evidence record's `commit` is the 40-char provenance value `b1fa1fbce647273643f404bc920a0ee1c134960d`. Compiler + dependency closure is bound by the review target (Solidity import closure from `src/` + declared tests) and `out/build-info/6fbe8915ea68f23f.json` (format `ethers-rs-sol-build-info-1`, 115 sources); dependency pins in `compatibility.lock.json`.

## Test evidence

- **85 local + 3 fork = 88 passed / 0 failed / 0 skipped.** Fuzz `runs=256`; invariant `runs=256, depth=30`. Suite map in `TEST_PLAN.md`.
- **Permission mask** `0x10cc` (afterInitialize, beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta) — CREATE2 address low bits + `getHookPermissions()` reproduced by `test_hookAddress_encodesMask0x10cc`, `test_getHookPermissions_exactlyFiveFlags`. Every entrypoint `onlyPoolManager`.
- **Solvency invariant** `balance == reserveQuote + Σ programmableFeeOwed` holds after every swap/claim (`invariant_solvency`, `testFuzz_08_solvencyInvariant`, fork).

## Static-analysis dispositions

Slither 0.11.6: **1407** total results across **130** contracts (High 27 / Medium 149 / Low 193 / Info 1020 / Opt 18). **12** touch the review-target `src/`; all false-positive or informational:

| Detector | Impact | Disposition |
| --- | --- | --- |
| `unused-return` (`claimProgrammableFee` → `poolManager.unlock`) | Medium | FP — `unlockCallback` returns empty `bytes("")` by design; any failure reverts atomically. **The only H/M touching src/.** |
| `reentrancy-benign` ×2 (`_afterSwap`, `_collect`) | Low | FP — external calls target the trusted PoolManager inside its own lock; no untrusted callee. |
| `reentrancy-events` ×5 (`_afterSwap`, `_collect`, `claimProgrammableFee`, `_topUpToFloor`) | Low | FP — CEI respected (liability zeroed before `unlock`; `reserveQuote` decremented before `settle`); event-ordering only. |
| `pragma` | Info | INFO/FP — src pins exact `0.8.26`; the spread is in third-party deps. |
| `missing-inheritance` (IUnlockCallback) | Info | INFO — implements the exact `unlockCallback` signature + `onlyPoolManager`; dispatched by selector. |
| `naming-convention` (`_poolId`) | Info | INFO/FP — leading underscore intentionally avoids shadowing the `poolId` state variable. |
| `unimplemented-functions` (`getHookPermissions`) | Info | FP — implemented as `public pure override` (L216-233); abstract `BaseHook` confuses the detector. |

No true-positive bug. Full rationale + line numbers: `evidence/slither-hook-triage.md`; machine-readable: `evidence/slither-hook-findings.json`.

## Gas and size

- Hook **runtime size 8,004 bytes**, initcode 9,318 bytes (16,572-byte runtime margin under EIP-170).
- Per-test gas snapshot: `.gas-snapshot` (fuzz means seed-dependent; medians stable).

## Dependency evidence

| Id | Chain / address | Interface / source | Runtime / block | RPC | Deployment record |
| --- | --- | --- | --- | --- | --- |
| `v4-poolmanager` | 1 / `0x000000000004444c5dc75cB358380D2e3dE08A90` | `@uniswap/v4-core@1.0.2` (npm, sha512 pinned in `compatibility.lock.json`) | runtimeHash `0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293`, block 25666892 (also at head) | public archive (`https://eth.drpc.org`) + Sourcify v2 | `v4-poolmanager-ethereum` (trust tier `pinned-official-feed-snapshot`); Sourcify runtime+creation match; `sourceRevision` unresolved by the pinned feed (`deployment-evidence.json`) |

No offchain dependency exists in the trust path.

## Root programmableFee policy

- Policy `programmable-volume-fee-v1` v`1.0.0`; scope `canonical-launch-pool-key`; basis gross-quote-side, quote asset `canonical-pool-quote-asset` (WETH).
- Rates: `effective = max(selected, 1000)`, `platform = 1000`, `project = effective - 1000`; LP fee excluded; non-additive (`3% → 0.1% + 2.9%`, never `3.1%`). Worked: `0 → 10 bps + 0`. Tested by `test_01_rateLevels_platformAlways10bps`, `test_02_nonAdditive_3pct`, `testFuzz_feeSplit`.
- All four executed gross quote-side modes (both currency orderings): `test_03_quadrants_quote0/quote1`, `test_04_basisIsExecutedNotRequested`, plus mainnet fork.
- Quadrant before/after paths: collect BEFORE iff quote is specified, else AFTER (`swapModePaths` in `submission.json`). `selfCallPolicy = same-pool-swap-forbidden` — the hook issues no `poolManager.swap`; proven by `Reentrancy.*` (nested unlock reverts `AlreadyUnlocked`).
- Ownership: immutable owner `0x4957f49620AFf3Adbbe8195a4f633E49cc93376c`, `claimAuthority = owner-only`, `claimAvailability = anytime`, `claimDestinationPolicy = owner-or-owner-selected-per-claim`, `storedMutableRecipient = false`; no builder/project/administrator mutation, no rescue/sweep/redirect. Tested: `test_07_ownerClaimsToArbitraryDestinations`, `test_08_nonOwnerCannotClaim`, `test_09_noStoredRecipient_ownerOnlyRedirect`, `HardValues.test_nonOwnerClaim_reverts_*`, `invariant_platformLiabilityClaimable`.
- Accounting: `accrualMode = claimable-liability` (not auto-transfer), keys `(poolId, currency, owner)`, `crossPoolNetting = false`; value-flow `swap-volume-charge`. Events `ProgrammableFeeCollected` / `ProgrammableFeeClaimed`; reconciliation `test_11_eventsReconcile`, `test_10_solvencyAndNoCrossPoolNetting`, `AntifragileTwoPoolInvariant.invariant_noCrossPoolNetting`. Accrual + partial/full claim reconcile to remaining liability + backing (`OwnerReserveIsolation.*`).
- Source/test binding: `hook.feeMechanism` ↔ `src/AntifragileFloorHook.sol` (+ `src/lib/FloorMath.sol`); fee tests `test/ProgrammableFee.t.sol`, `test/FloorHonor.t.sol`, `test/audit/FeeBypassAndAccounting.t.sol`, `test/audit/OwnerReserveIsolation.t.sol`, invariants, and `test/fork/AntifragileFork.t.sol`.

## Two fixed criticals

- **Reserve-drain (partial-fill top-up sized on requested tkn)** — FIXED `cd2109a`; top-up sized on executed `tknDelta`; regression `ReserveDrainRegression.*`.
- **Floor manipulation via malicious `totalSupply()` (audit 1.2)** — FIXED `b1fa1fb` via immutable `backedSupplySnapshot` at `_afterInitialize`; live `totalSupply()` removed from the floor path; PoC `TokenModel.test_adminBurnAnyone_mitigatedByImmutableSnapshot_noOverExtraction`. Details `docs/AUDIT.md`.

## Provenance separation

- **builder-stated** — product intent, immutable owner address, MIT license (`LICENSE`).
- **agent-derived** — quadrant predicate, split arithmetic, solvency identity.
- **evidence-backed (local, untrusted)** — the gate table above.
- **not established** — independent review, deployment receipts, source verification of the *hook*, runtime matching of the *hook*, lifecycle proof, routing review, product availability. The hook is **not deployed**.

## Release gate ledger (all rows OPEN — maintainer-owned)

| Row | State | Owner | Blocker / next action |
| --- | --- | --- | --- |
| Maintainer acceptance | not-started | Programmable maintainers | Automation cannot accept its own output (`human-economic-and-security-review`). |
| Independent security / economic review | required | independent reviewer | Custom accounting + `beforeSwapReturnDelta` + external-liquidity triggers require specialist review. |
| Platform integration review | not-started | maintainers | No UI/API/indexer implemented; boundaries specified only. |
| Deployment authorization + execution | not-started | maintainers | The hook is not deployed; no receipt. |
| Source verification (hook) / runtime matching (hook) | not-started | maintainers | Requires a deployed hook address; only the PoolManager dependency runtime is bound. |
| Lifecycle verification / monitoring readiness | not-started | maintainers | Post-deployment, maintainer-owned. |
| Hooklist / routing / discovery | not-submitted | external providers | `routingMode = not-planned`. |
| Product availability | not-started | maintainers | Requires all rows above. |

Contributor-owned `gate-status.json` records prototype checks only; it cannot complete any row above. No local check here proves audit, acceptance, product integration, deployment, live fee collection, verification, routing approval, provider support, or availability.
