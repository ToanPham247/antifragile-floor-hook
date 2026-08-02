# antifragile-floor-hook
Antifragile Floor: a Uniswap v4 hook with a self-funded, monotonic on-chain price floor (Programmable Hookathon).

See [`docs/PROPOSAL.md`](docs/PROPOSAL.md) for the design.

## Status

Compiling, tested **scaffold**. The hook currently declares its permission surface (mask `0x10cc`)
and ships valid stub callbacks — **no business logic yet** (floor accounting, fee capture, custody
and claims arrive in later TDD tasks).

## Pinned baseline

Dependencies are pinned to one coherent baseline (recorded in
[`compatibility.lock.json`](compatibility.lock.json)):

| Component | Version |
| --- | --- |
| `@openzeppelin/uniswap-hooks` (BaseHook) | `1.1.1` |
| `@openzeppelin/contracts` | `5.5.0` |
| `@uniswap/v4-core` (PoolManager, Hooks, Deployers) | `1.0.2` |
| `@uniswap/v4-periphery` (HookMiner) | `1.0.3` |
| `forge-std` (bundled in v4-core) | `1.9.3` |
| solc / evm | `0.8.26` / `cancun` |

## Build & test

```bash
npm install --ignore-scripts   # restores node_modules from the committed package-lock.json
forge build
forge test -vvv
```

Foundry remappings resolve into `node_modules/` (see `remappings.txt`), so `npm install` must run
before `forge build`.
