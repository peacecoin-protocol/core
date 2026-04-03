# PCE Token Core

Solidity smart contracts for PCEToken (ERC20, UUPS proxy) and PCECommunityToken (ERC20, Beacon proxy) on Polygon.

## Build & Test

```bash
forge build
forge test
```

## Upgrade Contracts

Always use `script/upgrade.sh` for upgrades. Do NOT run `forge script` directly for upgrade scripts — the OZ storage layout check will fail without a reference contract.

```bash
# Previous version tag is auto-detected from the latest git tag.

# DEV
./script/upgrade.sh script/UpgradeDEV.s.sol --broadcast --fork-url polygon --interactives 1

# Production
./script/upgrade.sh script/Upgrade.s.sol --broadcast --fork-url polygon --interactives 1

# Override auto-detection if needed
PREV_TAG=v10 ./script/upgrade.sh script/UpgradeDEV.s.sol --broadcast --fork-url polygon --interactives 1
```

The script validates storage layout compatibility by building the previous version from a git tag, then runs the forge script with the OZ check skipped (since it was already done externally via CLI).

**After each upgrade, tag the release:**

```bash
git tag v12
git push origin v12
```

## Key Architecture

- `src/PCEToken.sol` — Main PCE token (UUPS upgradeable proxy)
- `src/PCECommunityToken.sol` — Community tokens (Beacon proxy, one per community)
- `script/UpgradeDEV.s.sol` — DEV environment upgrade (Polygon mainnet)
- `script/Upgrade.s.sol` — Production upgrade (Polygon mainnet)
- `script/upgrade.sh` — Upgrade wrapper with storage layout validation

## Versioning

- Versions are tracked via git tags (v2, v4, v5, v6, v8, v9, v10, v11, ...)
- Pre-v11: versioned files (`PCETokenV10.sol`), post-v11: single files with git history
- `version()` function in each contract returns the current version string (e.g., `"1.0.11"`)

## Contract Addresses

### DEV (Polygon mainnet)
- PCEToken proxy: `0x62Ef93EAa5bB3E47E0e855C323ef156c8E3D8913`
- PCECommunityToken beacon: `0xA9D965660dcF0fA73E709fd802e9DEF2d9b52952`
- GovernanceReceiver: `0x36C4e7614Cb30a7FFEA6D03d2d3430B784DF1b8D`
- Polygon Timelock: `0xd9c349725412119E7acae54398DFF839BC59583E`

### DEV (Ethereum mainnet)
- Governor: `0x00831a36ce3535EFFeFe54BaD0bb8dE27687a237`
- WPCE (voting token): `0xeB5e0632eD3C635E0fa07420A328b49a7D0E6e6d`
- Ethereum Timelock: `0x208983f723245C765b4F9E57FAaB2633c9DDaC6B`
- GovernanceSender: `0xE86F98715D41A2E68a7FE279237130987dFbF2CF`

### Production (Polygon mainnet)
- PCEToken proxy: `0xA4807a8C34353A5EA51aF073175950Cb6248dA7E`
- PCECommunityToken beacon: `0x6A73A610707C113F34D8B82498b6868e5f7FAA74`

### GovTest (short-lived test governance)
- Deploy scripts: `script/DeployGovTestPolygon.s.sol`, `script/DeployGovTestEthereum.s.sol`
- Parameters: votingDelay=1 block, votingPeriod=10 blocks, quorum=1%, timelock=60s
- Addresses: populated after deployment (see `.env`)
