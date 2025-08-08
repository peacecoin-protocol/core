# Deploying PCE Governance

This guide walks through deploying the complete governance system for PeaceCoin.

## Prerequisites

1. WPCE token already deployed
2. Environment variables configured:
   ```bash
   export WPCE_TOKEN_ADDRESS=0x...  # Your WPCE token address
   export PRIVATE_KEY=0x... # Deployer private key
   export RPC_URL=https://...       # Your RPC endpoint
   ```

## Deployment Steps

### 1. Deploy Governor and Timelock

```bash
forge script script/DeployGovernance.s.sol:DeployGovernance \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify
```

This deploys:
- TimelockController (2-day delay)
- PCEGovernor (proxy + implementation)

Save the output addresses:
```bash
export GOVERNOR_ADDRESS=0x...    # From deployment output
export TIMELOCK_ADDRESS=0x...    # From deployment output
```

### 2. Transfer Ownership to Timelock

#### Transfer WPCE Token Ownership

```bash
forge script script/TransferWPCEOwnership.s.sol:TransferWPCEOwnership \
  --rpc-url $RPC_URL \
  --broadcast
```

#### Transfer PCE Token Roles

```bash
export PCE_TOKEN_ADDRESS=0x...  # Your PCE token address

forge script script/TransferPCERoles.s.sol:TransferPCERoles \
  --rpc-url $RPC_URL \
  --broadcast
```

Note: Governor upgrades are already controlled by Timelock via UUPS pattern.

## Governance Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| Voting Delay | 1 day | Time before voting starts |
| Voting Period | 7 days | Duration of voting |
| Proposal Threshold | 1000 WPCE | Min tokens to create proposal |
| Quorum | 4% | Min participation for validity |
| Timelock Delay | 2 days | Delay before execution |

## Testing Governance

### 1. Get WPCE Tokens

First, wrap some PCE tokens to get WPCE.

### 2. Delegate Voting Power

Before creating proposals, delegate to yourself:

```javascript
// In Etherscan or web3
wpce.delegate(yourAddress)
```

### 3. Create Test Proposal

Create a proposal by calling the Governor contract directly with sufficient WPCE tokens (1000+).

### 4. Vote and Execute

1. Cast your vote by calling the Governor contract
2. Wait for voting period to end
3. Queue the proposal if it passes
4. Execute after timelock delay

## Local Testing

For local testing with test tokens:

```bash
# Deploy everything including test tokens
forge script script/DeployGovernance.s.sol:DeployGovernanceWithTestToken \
  --rpc-url http://localhost:8545 \
  --broadcast
```

## Important Notes

1. **Initial Control**: Deployer has initial control, transfers to Timelock
2. **Irrevocable**: Once transferred to Timelock, only governance can make changes
3. **Emergency**: Consider keeping a multisig as Timelock executor for emergencies
4. **Upgrades**: Governor is upgradeable, but only through governance proposals

## Troubleshooting

### "Insufficient voting power"
- Ensure you've delegated voting power to yourself
- Check you have enough WPCE tokens

### "Proposal already exists"
- Each proposal has unique ID based on parameters
- Change description to create new proposal

### "Transaction reverted"
- Check all addresses are correct
- Ensure contracts are verified
- Confirm you're calling from the right account
