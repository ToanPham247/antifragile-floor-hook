# Internal Adversarial Security Audit — Antifragile Floor Hook

Scope: `src/AntifragileFloorHook.sol`, `src/lib/FloorMath.sol`. Method: hostile-auditor pass — for every
plausible attack, either a Foundry PoC proving a real bug (→ fix + regression) or a documented mitigation
citing the exact invariant/line that stops it. This register feeds `THREAT_MODEL.md`.

**Result:** no NEW in-model exploitable bug found. The prior CRITICAL reserve-drain (requested-vs-executed
top-up, fixed at `cd2109a`) was re-probed for variants — none escape the fix. The one value attack that was
previously out-of-model (a malicious `burn-anyone` / rebasing TKN can spike `floorHigh` and over-extract the
reserve — finding 1.2) has since been **FIXED**: `backedSupply` is now an **immutable snapshot** captured
once at `_afterInitialize`, so the live `totalSupply()` is removed from the floor path and no post-init
supply change can move the floor (see finding 1.2 below and `docs/FLOOR.md`). One **Low** lifecycle griefing
(binding front-run) is documented.

Suite after this audit + the 1.2 hardening: **88 tests green** (73 pre-existing + 14 `test/audit/*` +
**1 new** positive floor-immunity test), incl. mainnet-fork.

---

## Findings register

| # | Attack vector | Severity | Status | Evidence (PoC / mitigating code) | One-line reasoning |
|---|---------------|----------|--------|----------------------------------|--------------------|
| **1. Floor / reserve economics** |
| 1.1 | Partial-fill top-up sized on *requested* not *executed* tkn (prior CRITICAL) | Critical | **exploitable-FIXED** (`cd2109a`) | `ReserveDrainRegression.*`; `_afterSwap` `execTknIn = tknDelta<0?..:0` (src L337-338, L352) | Top-up sized on executed `tknDelta`, never `|amountSpecified|`; regression + my `test_burnOwnSupply` re-assert the bound. |
| 1.2 | Malicious/rebasing TKN craters `totalSupply` → spikes `floorHigh` → over-extract reserve | Medium (High-impact) | **exploitable-FIXED (immutable backedSupply snapshot)** | `TokenModelBoundary.test_adminBurnAnyone_mitigatedByImmutableSnapshot_noOverExtraction` | Floor now reads an IMMUTABLE `backedSupplySnapshot` taken once at `_afterInitialize` — the live `totalSupply()` is removed from the floor path. Cratering supply no longer moves `floorHigh` (0.0598 → **0.0599**, not 5.9203) and the redemption is bounded to fair value (extraction **2.49** vs the pre-fix 294.3 QUOTE; reserve drain **0.82** vs 294.3). Solvency + the 10bps liability preserved as before (§ Token assumptions). |
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

## Finding 1.2 — the fix, in numbers (exploitable-FIXED)

**The attack (BEFORE).** With a *live* `floorPrice = reserveQuote · 1e18 / totalSupply(tkn)` and a monotonic
`floorHigh`, a TKN whose supply can be cut **without cutting the attacker's own balance** (admin
`burn(anyone)`, negative rebase) let a fractional holder permanently spike `floorHigh`, then redeem their
untouched bag against the illegitimate floor:

```
BEFORE (live totalSupply — exploitable):
  floorHigh (honest)      = 0.0598  QUOTE/TKN
  floorHigh (post-burn)   = 5.9203  QUOTE/TKN     (~99× spike from cratering supply)
  attacker TKN delivered  = 50 TKN
  fair value @ honest floor = 2.99   QUOTE
  reserve before attack   = 299.0  QUOTE
  top-up EXTRACTED        = 294.3  QUOTE          (~98% of the whole reserve)
  reserve after attack    = 5.16   QUOTE
```

**The hardening.** `backedSupply` is now an **immutable `backedSupplySnapshot`** captured once at
`_afterInitialize` (bind time); the live `totalSupply()` read is removed from the floor path entirely
(`_backedSupply()` returns the snapshot). Cratering supply after init cannot move the floor at all.

```
AFTER (immutable snapshot — mitigated; PoC test_adminBurnAnyone_mitigatedByImmutableSnapshot_noOverExtraction):
  snapshot supply (frozen at bind) = 5000 TKN
  live supply after burn           = 50.6 TKN      (attacker STILL craters live supply ~99×)
  floorHigh (honest / snapshot)    = 0.0598 QUOTE/TKN
  floorHigh (post-burn)            = 0.0599 QUOTE/TKN   (UNCHANGED — moved only by this sell's own fee,
                                                          NOT by the crater; the ~99× spike is gone)
  floorHigh the crater WOULD force = 5.9104 QUOTE/TKN   (what a live denominator would have produced)
  attacker TKN delivered  = 50 TKN
  fair value @ snapshot floor = 2.995 QUOTE
  reserve before attack   = 299.0  QUOTE
  top-up (bounded, fair)  = ~2.5   QUOTE           (seller receives 2.49 QUOTE — the fair floor value)
  reserve NET drained     = 0.82   QUOTE           (0.27% — vs 294.3 / ~98% before)
  reserve after attack    = 298.18 QUOTE
```

The over-extraction is **closed**: the attacker who once turned 50 TKN (worth 2.99 QUOTE) into 294.3 QUOTE
now receives only **2.49 QUOTE** — the honest fair value of the TKN they delivered — and the shared reserve
is essentially untouched (299.0 → 298.18). All the prior bounds still hold:
* the top-up never exceeds `floorHigh · executedTkn / 1e18` (the cd2109a fix bound);
* the payout is capped by `reserveQuote` → the hook stays **solvent** (`balance == reserve + owed`);
* `programmableFeeOwed` (the owner's 10bps) is **untouched and still fully claimable**.

The out-of-model FoT / reentrant-quote assumptions below still stand; this fix specifically neutralizes the
`totalSupply`-manipulation vector on the floor path (it also makes a reverting/reentrant `totalSupply()`
irrelevant to swaps, since the floor no longer calls it — see finding 4.5).

### Why every supply-manipulation is now safe (post-hardening)

With the floor denominator FROZEN at the bind-time snapshot `S₀`, no post-init supply change touches the
floor. For reserve `R`, attacker holding `h`, any burn `b` (own OR anyone else's) and sell `h−b`:

```
floorHigh  → R·1e18/S₀            (S₀ constant — the crater's `S−b` is gone)
extraction ≤ floorHigh·(h−b)/1e18 = R·(h−b)/S₀   ≤ R·h/S₀   (maximized at b = 0)
```

Cutting **someone else's** supply (`burn-anyone`) no longer increases the denominator, so the ~99× spike is
impossible; extraction is bounded by `R·h/S₀` = the honest floor-value of the holding (finding 1.2 fixed).
Burning **your own** tokens is still no better (fewer tokens to redeem, floor unchanged); negative rebase is
inert on the floor. `test_adminBurnAnyone_mitigatedByImmutableSnapshot_noOverExtraction`,
`test_burnOwnSupply_topUpBoundedByExecutedFairValue` and `test_floorImmuneToPostInitSupply_mintAndBurn`
confirm the bound empirically.

---

## Token assumptions / out-of-model

The hook is **solvent against any ERC-20** (every top-up is capped by `reserveQuote ≤ its ERC-6909 claim
balance`; the fee is minted as claims and the split is exact). Since the finding-1.2 hardening the floor
denominator is an **immutable bind-time snapshot**, so a *non-standard* TKN can no longer break the **floor
VALUE guarantee** by moving supply post-init either. `totalSupply()` is now read only ONCE, at bind time.

| TKN behavior | Effect on floor (post-snapshot) | Bound |
|--------------|-----------|-------|
| Fixed-supply ERC-20 (the intended model) | snapshot == live → floor value meaningful and honest (unchanged) | — |
| ERC20Burnable (burn-your-own) after init | none — floor reads the frozen snapshot | Solvent; not profitable |
| Mintable / inflationary supply after init | none — snapshot understates supply → floor slightly higher, reserve-capped | No drain (finding 1.4) |
| **`burn-anyone` / admin burn / negative rebase after init** | **none — floor immune (FIXED)**; the crater cannot spike `floorHigh` | Bounded to fair value; solvency + 10bps intact (finding 1.2) |
| Fee-on-transfer / deflationary-on-transfer TKN | out-of-model; TKN-side FoT changes executed `tknDelta` only, floor denominator is frozen | Solvency unaffected (quote-side accounting) |
| `totalSupply()` reverts / unbounded gas at bind | reverts `_afterInitialize` → pool never binds (fail-safe); post-init reverts are irrelevant (not read) | No state corruption; swaps no longer brickable (finding 4.5) |
| Reentrant `totalSupply()` after init | never invoked on the swap path → reentry cannot fire (plus STATICCALL/`AlreadyUnlocked`/`onlyPoolManager`) | No drain/double-spend (3.3, 3.4) |

**Quote-side assumptions:** the quote currency is assumed a standard, non-reentrant, non-fee-on-transfer
ERC-20 (fee/reserve are held as exact ERC-6909 claims; payout uses `take`, so a FoT quote would short the
owner's chosen destination — an owner-accepted property). The immutable `OWNER` is the sole claimant of the
10bps; the project reserve is never owner-withdrawable by design.

**Deployment assumption (finding 4.1):** the canonical pool MUST be initialized atomically with (or under
exclusive control of) the deployer to avoid a binding front-run; the hook address is single-use and
re-mineable, so a grief costs the deployer only a redeploy.

---

## New tests added (`test/audit/`, 15 total)

| File | Tests | Covers |
|------|-------|--------|
| `TokenModel.t.sol` | 5 | finding-1.2 fix (admin-burn cannot spike floor / no over-extraction), burn-own bounded to snapshot floor, inflation no-drain, reverting `totalSupply` no longer bricks swaps, floor immune to post-init mint+burn |
| `BindingFrontrun.t.sol` | 3 | binding front-run griefing, re-bind forbidden, non-quote pool rejected |
| `ReentrancyDeeper.t.sol` | 2 | `totalSupply()` reentry (never invoked on swap path post-snapshot), claim payout CEI |
| `OwnerReserveIsolation.t.sol` | 3 | owner can’t reduce reserve, drain-to-zero leaves liability payable, no external reserve mutator |
| `FeeBypassAndAccounting.t.sol` | 2 | fee fragmentation never under-charges, ERC-6909 donation inert/unstealable |

Line references (`src L…`) are into `src/AntifragileFloorHook.sol` at the audited commit; the finding-1.2
hardening (immutable `backedSupplySnapshot`) postdates that commit.
