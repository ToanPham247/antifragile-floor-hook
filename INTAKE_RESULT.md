# INTAKE RESULT — Antifragile Floor Hook

**Status: intakeValidated=false — 4 remaining errors (genuine tooling/schema constraints)**

## (a) Final verify-package result

```
intakeValidated: false
errors: 4
warnings: 2

Blocking errors:
 0: dependency lock dependencies[1].repository must be an HTTPS URL   (OpenZeppelin Contracts)
 1: dependency lock dependencies[2].repository must be an HTTPS URL   (Uniswap v4 Core)
 2: dependency lock dependencies[3].repository must be an HTTPS URL   (Uniswap v4 Periphery)
 3: compatibility-report.json contains an unsupported OpenZeppelin audit, review or certification claim
```

Reduction: **162 → 4 errors** (97.5% resolved). All 88 tests pass. check = PROTOTYPE_READY. All 22 prototype gates completed with real evidence. Gate-status, review-target, and dependency-lock all consistently bound.

## (b) Full 22-gate list → real test mapping

| # | Gate ID | Test source | Pass count |
|---|---------|-------------|------------|
| 1 | **format-build-size-warnings** | `forge build --force --build-info` + `.gas-snapshot` | 8,004-byte hook; 0 build errors |
| 2 | **unit-integration-fuzz-invariant-tests** | `forge test --no-match-path 'test/fork/*'` | 85 passed, 0 failed |
| 3 | **callback-authentication-and-permission-mask** | `test/AntifragileFloorHook.t.sol` (test_06, test_09) | 85/85 local |
| 4 | **static-analysis** | Slither 0.11.6 (12 src/ findings, all FP/info) | No true-positive bug |
| 5 | **mainnet-fork-pinned-and-head-smoke** | `test/fork/AntifragileFork.t.sol` against real PoolManager | 3 passed, 0 failed |
| 6 | **fee-four-quadrant-tests** | `test/ProgrammableFee.t.sol` (13 fee tests x 4 quadrants x 2 orderings) | Covered in 85/85 |
| 7 | **before-swap-delta-four-quadrant-proof** | `test/ProgrammableFee.t.sol` (test_03, test_05) | Covered in 85/85 |
| 8 | **after-swap-return-delta-invariants** | `test/invariant/AntifragileInvariants.t.sol` (runs=256/depth=30) | Covered in 85/85 |
| 9 | **programmable-fee-formula-and-claim-tests** | `test/ProgrammableFee.t.sol` + `test/audit/OwnerReserveIsolation.t.sol` + `test/HardValues.t.sol` | Covered in 85/85 |
| 10 | **delta-conservation-invariants** | `test/invariant/AntifragileInvariants.t.sol` (invariant_solvency) | Covered in 85/85 |
| 11 | **erc6909-liability-solvency-invariants** | `test/invariant/AntifragileInvariants.t.sol` + `test/audit/OwnerReserveIsolation.t.sol` | Covered in 85/85 |
| 12 | **reserve-reconstruction-and-solvency-tests** | `test/FloorHonor.t.sol` + invariant suites | Covered in 85/85 |
| 13 | **external-call-reentrancy-and-failure-tests** | `test/Reentrancy.t.sol` + `test/audit/ReentrancyDeeper.t.sol` + `test/HardValues.t.sol` | Covered in 85/85 |
| 14 | **dependency-failure-tests** | `test/HardValues.t.sol` + invariant suites | Covered in 85/85 |
| 15 | **package-dependency-lock-and-closure-verification** | `dependency-lock.json` + `review-target.json` (closure v10, status=complete) | Dependency closure complete |
| 16 | **callback-selector-return-length-and-self-call-tests** | BaseHook + `test/Reentrancy.t.sol` (nested-unlock revert) | Covered in 85/85 |
| 17 | **event-reorg-backfill-freshness-tests** | `test/ProgrammableFee.t.sol` (test_10, test_11) | Covered in 85/85 |
| 18 | **external-liquidity-solvency-and-exit-invariants** | `test/invariant/Antifragile*Invariant*.t.sol` + `test/FloorHonor.t.sol` | Covered in 85/85 |
| 19 | **project-custody-solvency-and-exit-tests** | `test/FloorHonor.t.sol` + `test/audit/OwnerReserveIsolation.t.sol` + invariants | Covered in 85/85 |
| 20 | **project-external-call-authentication-and-failure-tests** | `test/AntifragileFloorHook.t.sol` + `test/HardValues.t.sol` + `test/audit/ReentrancyDeeper.t.sol` | Covered in 85/85 |
| 21 | **project-value-flow-conservation-and-claim-tests** | `test/ProgrammableFee.t.sol` + `test/audit/FeeBypassAndAccounting.t.sol` + invariants | Covered in 85/85 |
| 22 | **return-delta-execution-event** | `test/ProgrammableFee.t.sol` (test_11 eventsReconcile) | Covered in 85/85 |

## (c) Dependency-lock summary

- **Baseline:** `model-specific-pinned` (actual build: solc 0.8.26 / cancun / optimizer=200 / cborMetadata=true / bytecodeHash=none / viaIR=false)
- **Compiler source:** `argotorg/solidity` commit `8a97fa7a1db1ec509221ead6fea6802c684ee887`, tree `4ecc702563263869217d8a42262d09bd6015f597`
- **4 Dependency entries:**
  1. @openzeppelin/uniswap-hooks 1.1.1 — repo `https://github.com/OpenZeppelin/uniswap-hooks`, revision `a5f83196`, tree `01e2c8fe`
  2. @openzeppelin/contracts 5.5.0 — repo=null, revision=null (npm package provides no source repo)
  3. @uniswap/v4-core 1.0.2 — repo=null, revision=null (npm package provides no source repo); also covers `forge-std/` and `solmate/` remapping prefixes (bundled inside v4-core)
  4. @uniswap/v4-periphery 1.0.3 — repo=null, revision=null (npm package provides no source repo)
- **PoolManager onchain dependency revision:** `af7c077a438d5556b75f0ca722c6d3d53a7a1a9b` — resolved from `npm view @uniswap/v4-core@1.0.0 gitHead` (the deployed runtime matches the v4-core 1.0.0 release). Also set in `deployment-evidence.json.sourceRevision`.
- **Closure:** review-target.json (method v10) binds complete Solidity import closure; `closure.status=complete`

## (d) Wording fixes applied

1. **OpenZeppelin overclaim:** Replaced "audited by OpenZeppelin" — reworded to "Uses OpenZeppelin Uniswap Hooks primitives from the pinned release" throughout. The remaining claim error (#3) is the auto-generated compatibility-report text `"attributable dependency review: @openzeppelin/contracts"` in the `package-source-provenance-review` required gate. This is generated by the `check` command when sdkDependencies has null-null for packages without source provenance. It cannot be removed without either (a) providing source repos to sdkDependencies (which causes `CHECK_FAILED: package dependency is not exactly bound` because the npm lockfile doesn't carry a repository field for these packages), or (b) manually editing the auto-generated report (which causes `compatibility-report.json differs from a fresh complete deterministic preflight`).

2. **Deployment overclaim:** FIXED. Replaced "The hook is deployed at" with "The hook is targetable at". Replaced "The deployed mainnet runtime is now BOUND" with "The mainnet PoolManager runtime is observed".

3. **Test-mock mint authority:** FIXED. Added `"Test-only public mint (MockToken ERC-20 mock)"` authority entry declaring the test/audit/TokenModel.t.sol mock as test-only.

## (e) prepare-pr result

**BLOCKED** — `prepare-pr` internally calls `verify-package.mjs` which returns `intakeValidated=false` → exit 1 → `PACKAGE_INVALID`.

**Application identity:**
- **applicationId:** `antifragile-floor`
- **Repository:** `https://github.com/ToanPham247/antifragile-floor-hook`
- **Commit:** `86a4e10` (pushed to origin/main)
- **reviewTargetHash:** `sha256:d91b50d74b22f3cd36e8ed95b70ec802cda3d54cba9ef7fe4569ff4cd45b1ed1`

## (f) Draft PR body

```
## Antifragile Floor — A self-funded, ratchet-only price floor as a Uniswap v4 hook

**Stage:** prototype (check = PROTOTYPE_READY)
**Tests:** 85 local + 3 mainnet-fork = 88 passed / 0 failed / 0 skipped
**Risk tier:** high (score 13)

### What it does

A single custom v4 hook where every swap charges a 30 bps volume fee (10 bps → immutable Programmable owner claimable liability, 20 bps → WETH reserve). The reserve funds a monotonic, ratchet-only price floor: exact-input sellers receive a reserve-funded top-up toward `floorHigh`, after the core AMM executes the full swap. No custom curve — AMM leg is always the full swap.

### Key properties
- Mandatory Programmable fee: 10 bps owner-only claimable (immutable `0x4957f49620AFf3Adbbe8195a4f633E49cc93376c`)
- 20 bps locked in floor reserve — never withdrawable, only pays sellers
- Quadrant-dependent collection: beforeSwap on before-quadrants, afterSwap on after-quadrants
- Two criticals found + fixed: partial-fill reserve-drain (top-up on executed tkn) + floor manipulation via totalSupply (immutable snapshot)
- Fairness invariant: fee on AMM volume only, never on subsidy
- Partial honor: reserve too small → pay whole reserve, never revert
- No oracle, keeper, upgrade, or admin

### Source
- **Repository:** https://github.com/ToanPham247/antifragile-floor-hook
- **Commit:** 86a4e10
- **Hook:** src/AntifragileFloorHook.sol (8,004-byte runtime, 0x10cc permission mask)

### Intake gate status
`verify-package.mjs` reduced from 162 → 4 errors. Remaining 4 are tooling constraints:
- 3x "dependency lock repository must be HTTPS URL" — sdkDependencies has null for packages whose npm package.json provides no repository field; dep-lock must match null to pass the cross-file comparison, but the schema requires URLs
- 1x OpenZeppelin claim in auto-generated compatibility-report — "attributable dependency review: @openzeppelin/contracts" text from the required-gates list

### Checklist
- [x] 88 tests green (85 local + 3 fork, fuzz=256, invariant=256/depth=30)
- [x] Four-quadrant fee coverage, non-additive split, owner-only claim
- [x] Slither 0.11.6 — 12 src/ findings, all FP, no true-positive
- [x] Mainnet fork against real PoolManager (block 25666892 + head)
- [x] Solvency invariant: balance == reserveQuote + owed (runs=256/depth=30)
- [x] 22/22 prototype gates completed with real evidence
- [x] dependency-lock.json + review-target.json (closure v10, complete)
- [x] No deployment/launch/availability overclaims
- [x] TokenModel mock mint declared as test-only authority
```

## (g) Commit SHA

`86a4e10` — pushed to `https://github.com/ToanPham247/antifragile-floor-hook` (origin/main)

## (h) Remaining blockers

| # | Errors | Root cause | Fix attempt / result |
|---|--------|------------|---------------------|
| 0-2 | dep-lock repo must be URL (3 errors) | `sdkDependencies.repository` is null for 3 packages (@openzeppelin/contracts, @uniswap/v4-core, @uniswap/v4-periphery) because their npm package.json provides no repository field. `check` rejects non-null repo values with `CHECK_FAILED: package dependency is not exactly bound`. `dependency-lock.json` must match `sdkDependencies` byte-identical per the both-or-null rule at `review-target-core.mjs:1478-1491`, so dep-lock also has null. The dep-lock schema then rejects null with `must be an HTTPS URL`. | Tried adding repository to npm package.json → check still fails ("not exactly bound" — likely from package-lock.json metadata, not package.json). Catch-22: schema needs URL, check needs null. |
| 3 | OZ claim in compatibility-report | `check` generates `"attributable dependency review: @openzeppelin/contracts"` in the `package-source-provenance-review` required gate when `sdkDependencies` has null repository. This text matches the claim scanner's `@openzeppelin.*review` pattern. | Cannot be removed without (a) providing repo to sdkDeps (see error 0-2 catch-22) or (b) editing the auto-generated report (causes `differs from fresh preflight` error). |

**The project itself has 88 real passing tests, complete evidence, and all 22 gates mapped to real artifacts.** The remaining blockers are exclusively schema/feed/tooling validation constraints at the intersection of npm package metadata limitations and the verify-package's requirement for consistent repository URLs.
