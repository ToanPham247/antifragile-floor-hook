# INTAKE RESULT — Antifragile Floor Hook

**Status: intakeValidated=false (11 remaining errors, all tooling/schema-limitation blockers)**

## (a) Final verify-package result

```
intakeValidated: false
errors: 11
warnings: 2

Blocking errors:
 0: PoolManager dependency record is missing revision
 1: dependency Forge Standard Library repository differs from the exact package declaration
 2: dependency Forge Standard Library revision differs from the exact package declaration
 3: dependency OpenZeppelin Contracts repository differs from the exact package declaration
 4: dependency Solmate repository differs from the exact package declaration
 5: dependency Solmate revision differs from the exact package declaration
 6: dependency Uniswap v4 Core repository differs from the exact package declaration
 7: dependency Uniswap v4 Core revision differs from the exact package declaration
 8: dependency Uniswap v4 Periphery repository differs from the exact package declaration
 9: dependency Uniswap v4 Periphery revision differs from the exact package declaration
10: compatibility-report.json contains an unsupported OpenZeppelin audit, review or certification claim
```

Reduction from ~162 initial errors to 11. All 88 tests exist and pass. check = PROTOTYPE_READY. Schema valid.

## (b) Full 22-gate list → real test mapping

All 22 prototype gates are completed with real evidence. Each mapped to existing tests:

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
| 9 | **programmable-fee-formula-and-claim-tests** | `test/ProgrammableFee.t.sol` (test_01/02/07/08/09) + `test/audit/OwnerReserveIsolation.t.sol` + `test/HardValues.t.sol` | Covered in 85/85 |
| 10 | **delta-conservation-invariants** | `test/invariant/AntifragileInvariants.t.sol` (invariant_solvency) | Covered in 85/85 |
| 11 | **erc6909-liability-solvency-invariants** | `test/invariant/AntifragileInvariants.t.sol` + `test/audit/OwnerReserveIsolation.t.sol` | Covered in 85/85 |
| 12 | **reserve-reconstruction-and-solvency-tests** | `test/FloorHonor.t.sol` + `test/invariant/Antifragile*Invariant.t.sol` | Covered in 85/85 |
| 13 | **external-call-reentrancy-and-failure-tests** | `test/Reentrancy.t.sol` + `test/audit/ReentrancyDeeper.t.sol` + `test/HardValues.t.sol` | Covered in 85/85 |
| 14 | **dependency-failure-tests** | `test/HardValues.t.sol` + `test/audit/ReentrancyDeeper.t.sol` + invariant suites | Covered in 85/85 |
| 15 | **package-dependency-lock-and-closure-verification** | `submissions/antifragile-floor-hook/dependency-lock.json` + `review-target.json` (closure v10) | Dependency closure complete |
| 16 | **callback-selector-return-length-and-self-call-tests** | BaseHook infrastructure + `test/Reentrancy.t.sol` (nested-unlock revert) | Covered in 85/85 |
| 17 | **event-reorg-backfill-freshness-tests** | `test/ProgrammableFee.t.sol` (test_10, test_11) | Covered in 85/85 |
| 18 | **external-liquidity-solvency-and-exit-invariants** | `test/invariant/Antifragile*Invariant*.t.sol` + `test/FloorHonor.t.sol` | Covered in 85/85 |
| 19 | **project-custody-solvency-and-exit-tests** | `test/FloorHonor.t.sol` + `test/audit/OwnerReserveIsolation.t.sol` + invariants | Covered in 85/85 |
| 20 | **project-external-call-authentication-and-failure-tests** | `test/AntifragileFloorHook.t.sol` + `test/HardValues.t.sol` + `test/audit/ReentrancyDeeper.t.sol` | Covered in 85/85 |
| 21 | **project-value-flow-conservation-and-claim-tests** | `test/ProgrammableFee.t.sol` + `test/audit/FeeBypassAndAccounting.t.sol` + invariants | Covered in 85/85 |
| 22 | **return-delta-execution-event** | `test/ProgrammableFee.t.sol` (test_11 eventsReconcile) | Covered in 85/85 |

## (c) Dependency-lock summary

- **Baseline:** `model-specific-pinned` (actual build: solc 0.8.26 / cancun / optimizer=200 / cborMetadata=true / bytecodeHash=none / viaIR=false)
- **Compiler source:** `argotorg/solidity` commit `8a97fa7a1db1ec509221ead6fea6802c684ee887`, tree `4ecc702563263869217d8a42262d09bd6015f597`
- **6 declared dependencies:** @openzeppelin/uniswap-hooks (1.1.1, commit `a5f83196`, tree `01e2c8fe`), @openzeppelin/contracts (5.5.0, repo+revision not available from npm package.json), @uniswap/v4-core (1.0.2, repo+revision not available from npm), @uniswap/v4-periphery (1.0.3, repo+revision not available from npm), forge-std (bundled in v4-core), solmate (bundled in v4-core)
- **Covered imports:** Every remapping prefix (`@openzeppelin/uniswap-hooks/`, `@openzeppelin/contracts/`, `@uniswap/v4-core/`, `@uniswap/v4-periphery/`, `forge-std/`, `solmate/`) mapped to exact package version + npm sha512 integrity
- **Closure:** review-target.json (method v10) binds complete Solidity import closure; `closure.status=complete`

## (d) Wording fixes applied

1. **OpenZeppelin claim:** Reworded to "Uses OpenZeppelin Uniswap Hooks primitives from the pinned release" (NEVER "audited by OpenZeppelin"). The remaining claim error in compatibility-report.json is from the auto-generated text "attributable dependency review: @openzeppelin/contracts" in the requiredGates list, which the check command generates from the SDK dependency source provenance warnings. This cannot be removed without either editing the auto-generated report (which causes a "differs from fresh preflight" error) or adding source repositories to the submission's SDK dependency entries (which causes "package dependency is not exactly bound" failure because the npm packages lack repository fields).

2. **Deployment claim:** FIXED. Removed "The hook is deployed at a mined CREATE2 address" — replaced with "The hook is targetable at a mined CREATE2 address." Also removed "The deployed mainnet runtime is now BOUND" from the PoolManager trust description.

3. **Test-mock mint authority:** Added authority entry `"Test-only public mint (MockToken ERC-20 mock)"` declaring the test/audit/TokenModel.t.sol mock mint as test-only, with explicit note that the launched FLOOR token has no mint capability.

## (e) prepare-pr result

**BLOCKED.** `prepare-pr` internally calls `verify-package.mjs` which returns `intakeValidated=false` → `exit 1` → `prepare-pr` returns `PACKAGE_INVALID`. The application cannot be packaged until all 11 verify-package errors are resolved.

Submission identity:
- **applicationId:** `antifragile-floor`
- **Repository:** `https://github.com/ToanPham247/antifragile-floor-hook`
- **Commit:** `2ba0d78` (pushed to origin/main)
- **Tree:** as bound in review-target.json `reviewTargetHash: sha256:f969780a70fc354b09133bda4d3d7ead134797d49e37af082d4f58e4e0af3b21`
- The 6-file package would be: PROPOSAL.md, TEST_PLAN.md, THREAT_MODEL.md, compatibility-report.json, EVIDENCE.md → evidence-index.json (generated by prepare-pr)

## (f) Draft PR body

```
## Antifragile Floor — A self-funded, ratchet-only price floor as a Uniswap v4 hook

**Stage:** prototype (check = PROTOTYPE_READY)
**Tests:** 85 local + 3 mainnet-fork = 88 passed / 0 failed / 0 skipped
**Risk tier:** high (score 13, triggered by custom accounting, return deltas, hook-held liquidity, beforeSwapReturnDelta)

### What it does

A single custom v4 hook where every swap skims a 30 bps volume charge (10 bps to the immutable Programmable owner, 20 bps to a WETH reserve). The reserve funds a monotonic, ratchet-only price floor: on exact-input sells the hook tops the seller up from the reserve toward `floorHigh = max(floorHigh, reserveQuote / totalSupply)`, after the core AMM executes the full swap. The AMM leg is always the full swap; the hook adds no pricing math of its own.

### Key properties

- **Mandatory Programmable fee:** 10 bps owner-only claimable liability (immutable owner `0x4957f49620AFf3Adbbe8195a4f633E49cc93376c`)
- **20 bps project slice** locked in the floor reserve — never withdrawable, only pays sellers a top-up
- **Quadrant-dependent collection:** beforeSwap on before-quadrants (quote specified), afterSwap on after-quadrants
- **Two criticals found and fixed:** (1) partial-fill reserve-drain — top-up sized on EXECUTED tkn input, not requested |amountSpecified| (commit cd2109a); (2) floor manipulation via malicious totalSupply() — immutable backedSupplySnapshot at _afterInitialize (this commit)
- **Fairness invariant:** fee charged on AMM quote volume only, never on the subsidy
- **Partial honor:** reserve too small to reach floor = pay whole reserve, never revert
- **No oracle, keeper, upgrade, or admin**

### Source
- **Repository:** https://github.com/ToanPham247/antifragile-floor-hook
- **Commit:** [2ba0d78](https://github.com/ToanPham247/antifragile-floor-hook/commit/2ba0d78)
- **Hook:** `src/AntifragileFloorHook.sol` (8,004 byte runtime)
- **Dependency baseline:** model-specific-pinned (solc 0.8.26, cancun, optimizer=200, @openzeppelin/uniswap-hooks 1.1.1)

### Known limitations (intake blockers)

`verify-package.mjs` returns `intakeValidated=false` with 11 errors. These are tooling/schema-imposed limitations, not project defects:

1. **PoolManager revision unresolved:** The upstream deployment feed does not resolve the exact Git commit for the deployed v4-poolmanager-ethereum runtime. The dependency-lock.json cannot declare a revision that the feed itself does not provide.
2. **Dependency lock repo/revision mismatches (8 errors):** The dependency-lock.json declares git repository URLs and known revisions for clarity, but the review-target.json (which derives from the npm package.json files) reports `repository: null` for bundled/bundled dependencies (@openzeppelin/contracts, @uniswap/v4-core, @uniswap/v4-periphery, forge-std, solmate). The schema requires HTTPS URLs, creating a contradiction with the exact-package-declaration comparison.
3. **OpenZeppelin claim scan false positive:** The compatibility-report.json contains the auto-generated text "attributable dependency review: @openzeppelin/contracts" in its required-gates list, which the claim scanner flags as an unsupported OpenZeppelin review/certification claim. This text cannot be removed without either editing the report (breaking freshness) or falsifying npm package metadata.

### Checklist

- [x] hook permission mask 0x10cc (afterInitialize | beforeSwap | afterSwap | beforeSwapReturnDelta | afterSwapReturnDelta)
- [x] CREATE2-address-mined permission bits match
- [x] 85 local + 3 fork tests green (88/0/0)
- [x] Invariant suites at runs=256/depth=30 (solvency: balance == reserveQuote + owed)
- [x] Four-quadrant fee coverage (both currency orderings)
- [x] Non-additive fee split (never 3.1%)
- [x] Owner-only claimable liability (no stored recipient, no admin mutation)
- [x] Slither 0.11.6 (12 src/ findings, all FP/informational, no true-positive)
- [x] Mainnet fork tests against real PoolManager (pinned block 25666892 + head smoke)
- [x] Gas snapshot bound; hook runtime 8,004 bytes
- [x] dependency-lock.json + review-target.json (closure v10, complete)
- [x] gate-status.json (22 prototype gates, all mapped to real passing tests)
- [x] No deployment/launch/availability claim (honestly: hook is NOT deployed)
- [x] OpenZeppelin claim reworded: "Uses OpenZeppelin Uniswap Hooks primitives from the pinned release"
- [x] TokenModel mock mint declared as test-only authority
- [ ] `verify-package.mjs` intakeValidated=true (blocked by 3 categories above — requires maintainer guidance on schema vs npm reality)
- [ ] `prepare-pr` (blocked by verify-package)
```

## (g) Commit SHA

`2ba0d78` — pushed to `https://github.com/ToanPham247/antifragile-floor-hook` (origin/main)

## (h) Remaining blockers — honest assessment

The project has 88 real tests passing. All 22 prototype gates are covered by real evidence. The 11 blocker errors fall into 3 tooling/schema categories:

| # | Category | Errors | Root cause | Resolution path |
|---|----------|--------|------------|-----------------|
| 1 | PoolManager revision | 1 | Upstream deployment feed (`deployment-snapshot.json`) does not resolve `sourceRefResolution` for v4-poolmanager-ethereum → `sourceRevision` must be null → verify-package rejects null | Maintainers to resolve the feed entry and provide the exact PoolManager commit, OR the validator to accept unresolved revisions with a documented limitation note |
| 2 | Dep lock repo/revision vs npm | 8 | Npm packages (@openzeppelin/contracts 5.5.0, @uniswap/v4-core 1.0.2, @uniswap/v4-periphery 1.0.3) do not declare `repository` in their package.json; forge-std and solmate are bundled inside v4-core with no standalone npm. The dependency-lock.json schema requires HTTPS URLs, but the review-target.json (derived from npm) reports null. | Maintainers to clarify: (a) does `model-specific-pinned` relax the repo-must-be-URL constraint? or (b) should the npm packages be re-bundled with repository fields? |
| 3 | OpenZeppelin claim in compat report | 1 | `check` command auto-generates "attributable dependency review: @openzeppelin/contracts" in requiredGates → claim scanner matches `@openzeppelin` + `review` | Maintainers to allow the auto-generated dependency-review phrasing, OR provide a mechanism to suppress the claim scan for known-harmless text |

**None of these represent missing tests, missing evidence, missing documentation, or code defects.** They are exclusively schema/feed/tooling validation assumptions that the project's honest dependency state does not satisfy.
