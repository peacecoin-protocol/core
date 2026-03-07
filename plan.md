# Community Treasury Wallet Implementation Plan

## Overview

Each community token gets a configurable treasury wallet. PCE tokens held in that wallet can be used for capital operations (増資/減資) that change the swap rate without minting new community tokens.

## Current Architecture Understanding

- `exchangeRate` (in `LocalToken`) determines the swap rate: `communityAmount = pceAmount * exchangeRate / 10^18`
- `depositedPCEToken` is the PCE reserve backing the community token (used as a ceiling check in `swapFromLocalToken`)
- Swap rate formula: higher `exchangeRate` = more community tokens per PCE = each community token is worth less PCE

## Mechanism Design

### 増資 (Capital Increase) — Add PCE backing, tokens become more valuable
1. Transfer `ΔP` PCE from treasury wallet → PCEToken contract (`depositedPCEToken` increases)
2. Adjust `exchangeRate` downward: `newRate = oldRate * oldDeposited / (oldDeposited + ΔP)`
3. **No new community tokens minted** — existing holders' tokens are now worth more PCE each
4. Effect: `swapFromLocalToken` gives more PCE per community token

### 減資 (Capital Decrease) — Remove PCE backing, burn community tokens
1. Specify amount of community tokens to burn (`ΔC`) — burned from the caller's balance
2. Calculate proportional PCE to return: `ΔP = ΔC * INITIAL_FACTOR / exchangeRate * pceFactor / communityFactor`
3. Transfer `ΔP` PCE from PCEToken contract → treasury wallet (`depositedPCEToken` decreases)
4. Burn `ΔC` community tokens from the caller
5. `exchangeRate` stays the same (proportional burn keeps rate consistent)

### Role: `TREASURY_MANAGER_ROLE`
- New role using OpenZeppelin AccessControl pattern (added to PCECommunityToken)
- Initially granted to community owner at creation time
- Transferable via `grantRole` / `revokeRole` — enables DAO governance migration
- Only this role can call `capitalIncrease` and `capitalDecrease`

## Implementation Steps

### Step 1: Add treasury wallet state to `PCECommunityToken`

New storage variables (appended after existing storage):
```solidity
address public treasuryWallet;
bytes32 public constant TREASURY_MANAGER_ROLE = keccak256("TREASURY_MANAGER_ROLE");
mapping(bytes32 => mapping(address => bool)) private _roles;
```

Use a lightweight custom role system (not full AccessControl to avoid storage layout conflicts with the upgradeable proxy). Two functions:
- `hasRole(bytes32 role, address account) → bool`
- `grantTreasuryManagerRole(address account)` — only current treasury manager can call
- `revokeTreasuryManagerRole(address account)` — only current treasury manager can call

### Step 2: Add `setTreasuryWallet` function

```solidity
function setTreasuryWallet(address wallet) external onlyTreasuryManager {
    treasuryWallet = wallet;
    emit TreasuryWalletSet(wallet);
}
```

### Step 3: Add `capitalIncrease` function to `PCECommunityToken`

```solidity
function capitalIncrease(uint256 pceAmount) external onlyTreasuryManager {
    // 1. Transfer PCE from treasury wallet to PCEToken contract
    // 2. Call PCEToken.addCapital(address(this), pceAmount) which:
    //    - transfers PCE from treasury to PCEToken
    //    - updates depositedPCEToken
    //    - recalculates exchangeRate
}
```

### Step 4: Add `capitalDecrease` function to `PCECommunityToken`

```solidity
function capitalDecrease(uint256 communityTokenAmount) external onlyTreasuryManager {
    // 1. Burn community tokens from caller
    // 2. Call PCEToken.removeCapital(address(this), communityTokenAmount) which:
    //    - calculates proportional PCE
    //    - transfers PCE to treasury wallet
    //    - updates depositedPCEToken
}
```

### Step 5: Add helper functions to `PCEToken`

```solidity
function addCapital(address communityToken, uint256 pceAmount, address treasuryWallet) external {
    // Only callable by the community token itself
    // 1. transferFrom(treasuryWallet, address(this), pceAmount) — requires prior approval
    // 2. depositedPCEToken += pceAmount
    // 3. exchangeRate = exchangeRate * oldDeposited / (oldDeposited + pceAmount)
}

function removeCapital(address communityToken, uint256 communityAmount, address treasuryWallet) external {
    // Only callable by the community token itself
    // 1. Calculate PCE amount from communityAmount at current rate
    // 2. depositedPCEToken -= pceAmount
    // 3. transfer PCE to treasuryWallet
}
```

### Step 6: Initialize treasury manager role

In `PCECommunityToken.initialize()` — cannot modify (proxy already deployed).
Instead, add a one-time setup function:
```solidity
function initializeTreasury(address wallet) external onlyOwner {
    require(treasuryWallet == address(0), "Already initialized");
    treasuryWallet = wallet;
    _roles[TREASURY_MANAGER_ROLE][_msgSender()] = true;
}
```

### Step 7: Add events

```solidity
event TreasuryWalletSet(address indexed wallet);
event CapitalIncreased(uint256 pceAmount, uint256 oldExchangeRate, uint256 newExchangeRate);
event CapitalDecreased(uint256 communityTokensBurned, uint256 pceReturned);
event TreasuryManagerRoleGranted(address indexed account);
event TreasuryManagerRoleRevoked(address indexed account);
```

### Step 8: Tests

- Test `initializeTreasury` sets wallet and grants role to owner
- Test `capitalIncrease` correctly adjusts exchangeRate and depositedPCEToken
- Test `capitalDecrease` burns tokens and returns PCE to treasury
- Test role transfer (grant to DAO, revoke from owner)
- Test unauthorized access is rejected
- Test edge cases (zero amounts, insufficient balances)

### Step 9: Version bump

Update `version()` to `"1.0.13"` in both contracts.

## File Changes Summary

| File | Changes |
|------|---------|
| `src/PCECommunityToken.sol` | Add treasury wallet, roles, capitalIncrease/Decrease, initializeTreasury |
| `src/PCEToken.sol` | Add addCapital, removeCapital functions |
| `test/PCE.t.sol` | Add treasury wallet tests |

## Storage Layout Safety

All new storage variables are **appended** after existing ones — safe for upgradeable proxies. No existing storage slots are modified.
