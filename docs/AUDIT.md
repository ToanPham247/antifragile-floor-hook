# Internal Adversarial Security Audit — Antifragile Floor Hook

Scope: `src/AntifragileFloorHook.sol`, `src/lib/FloorMath.sol`. Method: hostile-auditor pass — for every
plausible attack, either a Foundry PoC proving a real bug (→ fix + regression) or a documented mitigation
citing the exact invariant/line that stops it. This register feeds `THREAT_MODEL.md`.

**Result:** no NEW in-model exploitable bug found. The prior CRITICAL reserve-drain (requested-vs-executed
top-up, fixed at `cd2109a`) was re-probed for variants — none escape the fix. One **out-of-model** value
attack (a malicious `burn-anyone` / rebasing TKN can spike `floorHigh` and over-extract the reserve) is
mapped precisely with a PoC that also proves the damage is **bounded to the reserve — solvency and the
platform liability always survive**. One **Low** lifecycle griefing (binding front-run) is documented.

Suite after this audit: **87 tests green** (73 pre-existing + **14 new** `test/audit/*`), incl. mainnet-fork.

---

## Findings register

| # | Attack vector | Severity | Status | Evidence (PoC / mitigating code) | One-line reasoning |
|---|---------------|----------|--------|----------------------------------|--------------------|
| **1. Floor / reserve economics** |
| 1.1 | Partial-fill top-up sized on *requested* not *executed* tkn (prior CRITICAL) | Critical | **exploitable-FIXED** (`cd2109a`) | `ReserveDrainRegression.*`; `_afterSwap` `execTknIn = tknDelta<0?..:0` (src L337-338, L352) | Top-up sized on executed `tknDelta`, never `|amountSpecified|`; regression + my `test_burnOwnSupply` re-assert the bound. |
| 1.2 | Malicious/rebasing TKN craters `totalSupply` → spikes `floorHigh` → over-extract reserve | Medium (High-impact, out-of-model) | **out-of-model (documented)** | `TokenModelBoundary.test_adminBurnAnyone_overExtractsReserve_butSolventAndLiabilityIntact` | A `burn-anyone`/neg-rebase TKN lets a fractional holder drain ~98% of the reserve (294.3 vs 2.99 fair QUOTE) — but the top-up is still capped by `reserveQuote`, so **solvency + the 10bps liability survive** (§ Token assumptions). |
| 1.3 | Burn-your-own supply (ERC20Burnable) to over-redeem | Info | **mitigated (fix bound)** | `TokenModelBoundary.test_burnOwnSupply_topUpBoundedByExecutedFairValue` | Top-up ≤ `floorHigh*executedTkn/1e18`; burning your own tokens raises per-token floor but leaves fewer to redeem — net extraction only DROPS (algebra below). Not profitable. |
| 1.4 | Supply inflation (mint) to grief the floor / drain | Low | **mitigated** | `TokenModelBoundary.test_mintInflateSupply_noDrain_floorMonotonic` | `floorHigh` is a monotonic max; inflation lowers the *candidate* but never ratchets down, and a buy/above-floor sell pays no subsidy → no drain. |
| 1.5 | Donation / external inflation of `reserveQuote` besides fees | Info | **mitigated** | `OwnerReserveIsolation.test_noExternalReserveMutator`; `FeeBypassAndAccounting.test_erc6909Donation_inert_notStealable` | `reserveQuote` has NO external setter: rises only via the project fee slice, falls only via a below-floor sell top-up. An ERC-6909 claim donation inflates the raw balance but never `reserveQuote`/floor and is unstealable. |
| 1.6 | `floorHigh` monotonicity weaponized (promise > backing) | Low | **mitigated** | `FloorHonor.test_03_partialHonor`; `OwnerReserveIsolation.test_reserveDrainToZero_leavesLiabilityFullyBacked` | Payout is ALWAYS additionally capped by live `reserveQuote` (src L377). A stale-high floor causes *partial honor*, never insolvency. |
| **2. Mandatory fee bypass / theft** |
| 2.1 | Route around the fee (alt pool / transfer / LP-fee / multi-hop intermediate) | — | **mitigated** | `ProgrammableFee.test_05_onlyCanonicalPoolAccrues` | Fee accrues ONLY on the one bound canonical pool; hookless/alt pools and transfers never touch the hook. |
| 2.2 | Under-charge via rounding / tiny-amount fragmentation | Low | **mitigated (ceil)** | `FeeBypassAndAccounting.test_fragmentation_neverUndercharges`; `_ceilDiv` (src L465) | Every slice ceils independently, so fragmenting a swap pays MORE, never less; a 1-wei swap still charges ≥1 wei. |
| 2.3 | Exact-output gross-up to dodge/underpay | — | **mitigated** | `ProgrammableFee.test_03_quadrants_*`, `test_04_basisIsExecutedNotRequested`, fork | Fee basis is the executed gross across all 4 quadrants × both orderings; exact-out charges on executed input. |
| 2.4 | Non-owner claims / redirects / zeroes the liability | High (if broken) | **mitigated** | `ProgrammableFee.test_07/08/09`, `HardValues.test_nonOwnerClaim_reverts_*`, `AntifragileInvariants.invariant_platformLiabilityClaimable` | `claimProgrammableFee` is `msg.sender==OWNER` (immutable) only; no stored recipient; strangers revert `NotOwner`. |
| 2.5 | Cross-contamination `reserveQuote` ↔ `programmableFeeOwed` | High (if broken) | **mitigated** | `OwnerReserveIsolation.test_ownerClaimNeverReducesReserve`, `test_reserveDrainToZero_leavesLiabilityFullyBacked` | Claim burns only `owed`; top-up burns only `reserveQuote` (capped ≤ it). The two pots never cross; owner can’t touch the reserve, a floor drain can’t touch the liability. |
| **3. Delta / accounting** |
| 3.1 | Sign/precision error in `net = fee − topUp` across quadrants×orderings | High (if broken) | **mitigated** | `ProgrammableFee.test_03_quadrants_*`, `FloorHonor.*`, `AntifragileFork.*` | Both legs land on the same unspecified-quote currency; validated against the REAL mainnet PoolManager. |
| 3.2 | Rounding accumulation breaks exact solvency | High (if broken) | **mitigated** | `FloorHonor.testFuzz_08_solvencyInvariant`, `AntifragileInvariants.invariant_solvency` | `project = total − platform` (src L461) makes `platform+project ≡ total` with no drift; balance ≡ reserve+owed after every op. |
| 3.3 | Reentrancy via a malicious token `transfer`/`transferFrom` | High (if broken) | **mitigated** | `Reentrancy.test_reentrantToken_asTkn/asQuote_blocked` | Hook callbacks are `onlyPoolManager`; nested `manager.unlock` reverts `AlreadyUnlocked`. |
| 3.4 | Reentrancy via a malicious `totalSupply()` (different entrypoint) | High (if broken) | **mitigated (defense-in-depth)** | `ReentrancyDeeper.test_reentrantTotalSupply_cannotDrainOrDoubleSpend` | `_backedSupply()` is `view` (src L388) → the TKN supply is read via STATICCALL; a state-changing reentry there reverts (also caught by `AlreadyUnlocked`) and can’t drain/double-spend. |
| 3.5 | Reentrant double-claim during the owner payout | High (if broken) | **mitigated (CEI)** | `ReentrancyDeeper.test_claimPayout_isCEI_liabilityZeroedBeforeInteraction` | `programmableFeeOwed[..]=0` is written BEFORE the external unlock/payout (src L425-430); a reentrant claim observes 0. |
| **4. Access / lifecycle / DoS** |
| 4.1 | `afterInitialize` binding front-run → bound to a wrong PoolKey (griefing/DoS) | Low | **accepted-with-rationale** | `BindingFrontrun.test_bindingFrontRun_bindsWrongTkn_thenRealPoolDoSed` | Anyone can pre-bind the hook to a `(quote, attackerToken)` pool, souring the CREATE2 address; attacker gains nothing (owner+reserve inert on a junk pair), remedy = redeploy/re-mine. Deploy MUST initialize atomically. |
| 4.2 | Re-bind an already-bound hook to a second pool | — | **mitigated** | `BindingFrontrun.test_cannotRebindToDifferentTkn`, `HardValues.test_initializeTwice_reverts` | `_bound` guard reverts `PoolAlreadyBound` on any second init (src L237). |
| 4.3 | Bind a pool without the quote currency | — | **mitigated** | `BindingFrontrun.test_nonQuotePoolNeverBinds`, `HardValues.test_wrongPool_notQuotePool_reverts` | `_afterInitialize` reverts `NotQuotePool` if neither side is the quote (src L236). |
| 4.4 | CREATE2 permission-bit / declared-behavior mismatch | High (if broken) | **mitigated** | `AntifragileFloorHookTest.test_hookAddress_encodesMask0x10cc`, `test_getHookPermissions_exactlyFiveFlags` | Address low bits == `0x10cc`; `BaseHook` ctor re-validates; the hook uses exactly its declared callbacks. |
| 4.5 | DoS via reverting counterparty / recipient / reserve math | Low | **mitigated** / **out-of-model** | `Reentrancy.test_revertingToken_atomicNoStuckState`; `TokenModelBoundary.test_revertingTotalSupply_bricksSwaps_noCorruption` | Reverting settlement → whole swap reverts atomically (no stuck state). A TKN whose `totalSupply()` reverts bricks its own pool (out-of-model) but never corrupts hook state. |

---

## The one out-of-model attack, in numbers (finding 1.2)

`floorPrice = reserveQuote · 1e18 / totalSupply(tkn)` and `floorHigh` ratchets it up monotonically. A TKN
whose supply can be cut **without cutting the attacker's own balance** (admin `burn(anyone)`, negative
rebase) lets a fractional holder permanently spike `floorHigh`, then redeem their untouched bag against the
illegitimate floor:

```
PoC test_adminBurnAnyone_overExtractsReserve_butSolventAndLiabilityIntact:
  floorHigh (honest)      = 0.0598  QUOTE/TKN
  floorHigh (post-burn)   = 5.9203  QUOTE/TKN     (~99× spike from cratering supply)
  attacker TKN delivered  = 50 TKN
  fair value @ honest floor = 2.99   QUOTE
  reserve before attack   = 299.0  QUOTE
  top-up EXTRACTED        = 294.3  QUOTE          (~98% of the whole reserve)
  reserve after attack    = 5.16   QUOTE
```

The attacker turns 50 TKN worth **2.99 QUOTE** into **294.3 QUOTE** — a ~98× over-extraction of the shared
reserve. **BUT** the PoC also proves the blast radius is bounded:
* the top-up never exceeds `floorHigh · executedTkn / 1e18` (the cd2109a fix bound still holds);
* the payout is capped by `reserveQuote` → the hook stays **solvent** (`balance == reserve + owed`);
* `programmableFeeOwed` (the owner's 10bps) is **untouched and still fully claimable** after the drain.

### Why the IN-MODEL versions are safe (why 1.3 is not a bug)

Let reserve `R`, supply `S`, attacker holds `h`, burns `b` of their OWN tokens, sells `h−b`:

```
floorHigh  → R·1e18/(S−b)
extraction ≤ floorHigh·(h−b)/1e18 = R·(h−b)/(S−b)
d/db [ (h−b)/(S−b) ] = (h−S)/(S−b)² < 0   (since h < S)
```

So extraction is **maximized at `b = 0`** (no burn) at `R·h/S` = the honest floor-value of your holding.
Burning your own tokens is strictly *worse*. Negative rebase scales `h` down with `S`, leaving `h/S`
unchanged — also no gain. Only cutting **someone else's** supply (`burn-anyone`) increases `R·h/(S−b)`,
and that is the out-of-model primitive. `test_burnOwnSupply_topUpBoundedByExecutedFairValue` confirms the
bound empirically.

---

## Token assumptions / out-of-model

The hook is **solvent against any ERC-20** (every top-up is capped by `reserveQuote ≤ its ERC-6909 claim
balance`; the fee is minted as claims and the split is exact). What a *non-standard* TKN can break is the
**floor VALUE guarantee**, never solvency and never the platform liability.

| TKN behavior | In model? | Effect | Bound |
|--------------|-----------|--------|-------|
| Fixed-supply ERC-20 (the intended model) | ✅ yes | Floor value is meaningful and honest | — |
| ERC20Burnable (burn-your-own) | ✅ effectively | Cannot over-extract (algebra above) | Solvent; not profitable |
| Mintable / inflationary supply | ⚠️ tolerated | Lowers the *candidate* floor; `floorHigh` holds (monotonic) | No drain (finding 1.4) |
| **`burn-anyone` / admin burn / negative rebase** | ❌ **out-of-model** | Spikes `floorHigh`; a fractional holder can over-extract the reserve | **Reserve only**; solvency + 10bps liability intact (finding 1.2) |
| Fee-on-transfer / deflationary-on-transfer TKN | ❌ out-of-model | Accelerates reserve payout as supply drifts down; TKN-side FoT changes executed `tknDelta` only | Solvency unaffected (quote-side accounting) |
| `totalSupply()` reverts / unbounded gas | ❌ out-of-model | Bricks swaps on its own pool (DoS) | No state corruption (finding 4.5) |
| Reentrant `totalSupply()` / `transfer` | ❌ out-of-model | Attempts blocked by STATICCALL + `AlreadyUnlocked` + `onlyPoolManager` | No drain/double-spend (3.3, 3.4) |

**Quote-side assumptions:** the quote currency is assumed a standard, non-reentrant, non-fee-on-transfer
ERC-20 (fee/reserve are held as exact ERC-6909 claims; payout uses `take`, so a FoT quote would short the
owner's chosen destination — an owner-accepted property). The immutable `OWNER` is the sole claimant of the
10bps; the project reserve is never owner-withdrawable by design.

**Deployment assumption (finding 4.1):** the canonical pool MUST be initialized atomically with (or under
exclusive control of) the deployer to avoid a binding front-run; the hook address is single-use and
re-mineable, so a grief costs the deployer only a redeploy.

---

## New tests added (`test/audit/`, 14 total)

| File | Tests | Covers |
|------|-------|--------|
| `TokenModel.t.sol` | 4 | supply-crash floor spike (out-of-model drain, bounded), burn-own bound, inflation no-drain, reverting `totalSupply` DoS |
| `BindingFrontrun.t.sol` | 3 | binding front-run griefing, re-bind forbidden, non-quote pool rejected |
| `ReentrancyDeeper.t.sol` | 2 | `totalSupply()` reentry (STATICCALL guard), claim payout CEI |
| `OwnerReserveIsolation.t.sol` | 3 | owner can’t reduce reserve, drain-to-zero leaves liability payable, no external reserve mutator |
| `FeeBypassAndAccounting.t.sol` | 2 | fee fragmentation never under-charges, ERC-6909 donation inert/unstealable |

Line references (`src L…`) are into `src/AntifragileFloorHook.sol` at the audited commit.
