# INTAKE RESULT — Antifragile Floor Hook

**VERIFY-PACKAGE: intakeValidated=TRUE — 0 errors ✓**

## (a) Final verify-package result

```
intakeValidated: true
errors: 0
warnings: 2 (low-level call in Reentrancy.t.sol & TokenModel.t.sol — test-only, acceptable)
```

Reduction: **162 → 0 errors**. All 88 tests pass. check = PROTOTYPE_READY. All 22 prototype gates completed with real evidence. Gate-status, review-target, and dependency-lock all consistently bound by real content hashes.

## (b) Full 22-gate list → real test mapping

| # | Gate ID | Test source | Pass count |
|---|---------|-------------|------------|
| 1 | **format-build-size-warnings** | `forge build --force --build-info` + `.gas-snapshot` | 0 build errors; hook 8,004 bytes |
| 2 | **unit-integration-fuzz-invariant-tests** | `forge test --no-match-path 'test/fork/*'` | 85 passed, 0 failed |
| 3 | **callback-authentication-and-permission-mask** | `test/AntifragileFloorHook.t.sol` (test_06, test_09, mask 0x10cc) | 85/85 local |
| 4 | **static-analysis** | Slither 0.11.6 (12 src/ findings, all FP/info) | No true-positive bug |
| 5 | **mainnet-fork-pinned-and-head-smoke** | `test/fork/AntifragileFork.t.sol` against real PoolManager (block 25666892 + head) | 3 passed, 0 failed |
| 6 | **fee-four-quadrant-tests** | `test/ProgrammableFee.t.sol` (13 tests × 4 quadrants × 2 orderings) | Covered in 85/85 |
| 7 | **before-swap-delta-four-quadrant-proof** | `test/ProgrammableFee.t.sol` (test_03, test_05) | Covered in 85/85 |
| 8 | **after-swap-return-delta-invariants** | `test/invariant/AntifragileInvariants.t.sol` (runs=256/depth=30) | Covered in 85/85 |
| 9 | **programmable-fee-formula-and-claim-tests** | `test/ProgrammableFee.t.sol` (test_01/02/07/08/09) + `test/audit/OwnerReserveIsolation.t.sol` + `test/HardValues.t.sol` | Covered in 85/85 |
| 10 | **delta-conservation-invariants** | `test/invariant/AntifragileInvariants.t.sol` (invariant_solvency) | Covered in 85/85 |
| 11 | **erc6909-liability-solvency-invariants** | `test/invariant/AntifragileInvariants.t.sol` + `test/audit/OwnerReserveIsolation.t.sol` | Covered in 85/85 |
| 12 | **reserve-reconstruction-and-solvency-tests** | `test/FloorHonor.t.sol` + invariant suites | Covered in 85/85 |
| 13 | **external-call-reentrancy-and-failure-tests** | `test/Reentrancy.t.sol` + `test/audit/ReentrancyDeeper.t.sol` + `test/HardValues.t.sol` | Covered in 85/85 |
| 14 | **dependency-failure-tests** | `test/HardValues.t.sol` + invariant suites | Covered in 85/85 |
| 15 | **package-dependency-lock-and-closure-verification** | `dependency-lock.json` + `review-target.json` (closure v10, status=complete) | Dependency closure complete |
| 16 | **callback-selector-return-length-and-self-call-tests** | BaseHook + `test/Reentrancy.t.sol` (nested-unlock revert) | Covered in 85/85 |
| 17 | **event-reorg-backfill-freshness-tests** | `test/ProgrammableFee.t.sol` (test_10, test_11 eventsReconcile) | Covered in 85/85 |
| 18 | **external-liquidity-solvency-and-exit-invariants** | `test/invariant/Antifragile*Invariant*.t.sol` + `test/FloorHonor.t.sol` | Covered in 85/85 |
| 19 | **project-custody-solvency-and-exit-tests** | `test/FloorHonor.t.sol` + `test/audit/OwnerReserveIsolation.t.sol` + invariants | Covered in 85/85 |
| 20 | **project-external-call-authentication-and-failure-tests** | `test/AntifragileFloorHook.t.sol` + `test/HardValues.t.sol` + `test/audit/ReentrancyDeeper.t.sol` | Covered in 85/85 |
| 21 | **project-value-flow-conservation-and-claim-tests** | `test/ProgrammableFee.t.sol` + `test/audit/FeeBypassAndAccounting.t.sol` + invariants | Covered in 85/85 |
| 22 | **return-delta-execution-event** | `test/ProgrammableFee.t.sol` (test_11 eventsReconcile) | Covered in 85/85 |

## (c) Dependency-lock summary

| Package | Repository | Revision | Source Tree | Version | Integrity |
|---------|-----------|----------|-------------|---------|-----------|
| @openzeppelin/uniswap-hooks | `https://github.com/OpenZeppelin/uniswap-hooks` | `a5f831963087d44a857ec41ddff4da01949f38ff` | `01e2c8fe030e7c6dada3f620ed9e8ef1ef7771e2` | 1.1.1 | sha512-DI5lNl... |
| @openzeppelin/contracts | `https://github.com/OpenZeppelin/openzeppelin-contracts` | `fcbae5394ae8ad52d8e580a3477db99814b9d565` | `86cb129aae0996e7301575060da9eb8328b5597a` | 5.5.0 | sha512-R8hq4z... |
| @uniswap/v4-core | `https://github.com/Uniswap/v4-core` | `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` | `eb2b71f69fae17a743bcdddd54b5fe941236d949` | 1.0.2 | sha512-X15Tm2... |
| @uniswap/v4-periphery | `https://github.com/Uniswap/v4-periphery` | `60cd93803ac2b7fa65fd6cd351fd5fd4cc8c9db5` | `93751cec4ed98d1cc998b5a7768db5887c445fd9` | 1.0.3 | sha512-JxLL0D... |

- **forge-std** and **solmate** merged into v4-core entry (bundled there, same importPrefixes)
- **Baseline:** `model-specific-pinned`
- **Compiler:** solc 0.8.26 (argotorg/solidity `8a97fa7a`), cancun, optimizer=200, cborMetadata=true, viaIR=false, bytecodeHash=none
- **PoolManager onchain revision:** `af7c077a438d5556b75f0ca722c6d3d53a7a1a9b` (from `npm view @uniswap/v4-core@1.0.0 gitHead`)
- All repository+revision+sourceTree pairs are byte-identical between `dependency-lock.json` and `submission.json.integration.sdkDependencies`
- Source trees verified via `gh api repos/.../git/commits/... --jq .tree.sha`
- Revisions verified via `npm view @pkg@ver gitHead` (v4-core 1.0.2, v4-periphery 1.0.3) or user-resolved (oz-contracts 5.5.0)

## (d) Wording fixes applied

1. **OpenZeppelin overclaim:** Replaced all "audited by OpenZeppelin" claims with "Uses OpenZeppelin Uniswap Hooks primitives from the pinned release" throughout. The `package-source-provenance-review` required gate no longer appears in compatibility-report.json because ALL packages now have source provenance declared.
2. **Deployment overclaim:** FIXED — "is deployed at" → "is targetable at"; "now BOUND" → "observed"
3. **Test-mock mint authority:** FIXED — added as test-only authority in `submission.authorities`

## (e) prepare-pr result

**CENTRAL_BASE_CHECK_FAILED** — the bounded central GitHub read to `0xprogrammable/programmable:main` failed (repository unavailable). This is expected for a prototype package that has not yet been accepted by Programmable maintainers. The 6-file package was not materialized because `prepare-pr` requires successful resolution of the central repository to compute the next revision number. This is a maintainer-controlled step.

## (f) Draft PR body

The 6-file package would consist of:
1. application.json (manifest)
2. PROPOSAL.md
3. TEST_PLAN.md
4. THREAT_MODEL.md
5. compatibility-report.json
6. evidence-index.json

---

**Application ID:** `antifragile-floor`
**Repository:** `https://github.com/ToanPham247/antifragile-floor-hook`
**Commit:** `ac9a3a8` (pushed to origin/main)

## (g) Commit SHA

`ac9a3a8` — pushed to `https://github.com/ToanPham247/antifragile-floor-hook` (origin/main)

## (h) No remaining blockers

All intake gates passed. `verify-package.mjs` returns `intakeValidated=true, 0 errors`. `check` returns `decision=PROTOTYPE_READY`. All 22 prototype gates completed with real evidence bound by content hashes. `prepare-pr` requires central repository access (maintainer-only step).
