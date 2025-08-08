# PeaceCoin Governance

## Overview

The PeaceCoin governance system enables WPCE token holders to participate in protocol decisions through on-chain voting.

## Components

### 1. **WPCE Token (Voting Power)**
- ERC20Votes implementation
- Token holders delegate voting power
- 1 WPCE = 1 vote

### 2. **PCEGovernor Contract**
- Manages proposals and voting
- OpenZeppelin Governor implementation
- UUPS upgradeable (controlled by Timelock)
- Settings:
  - Voting Delay: 1 day (time before voting starts)
  - Voting Period: 1 week
  - Proposal Threshold: 1000 WPCE (minimum to create proposal)
  - Quorum: 4% of total supply

### 3. **Timelock Controller**
- Adds delay before executing proposals
- Default: 2 days
- Prevents malicious immediate execution

## How It Works

### Creating a Proposal
1. Hold at least 1000 WPCE
2. Delegate voting power to yourself
3. Call `propose()` on Governor contract with:
   - Target addresses
   - Values (ETH amounts)
   - Function calldata
   - Proposal description

### Voting Process
1. **Review Period** (1 day): Proposal is created but voting hasn't started
2. **Voting Period** (1 week): Token holders can vote
   - For
   - Against
   - Abstain
3. **Timelock** (2 days): If passed, proposal queued for execution
4. **Execution**: Anyone can execute the proposal

### Example Proposals

**1. Update Protocol Parameter**
```javascript
// Target: PCEToken contract
// Function: updateSwapFee(uint256 newFee)
// Value: 0
// Calldata: encoded function call
```

**2. Treasury Management**
```javascript
// Target: Treasury contract  
// Function: transfer(address to, uint256 amount)
// Value: 0
// Calldata: encoded transfer
```

**3. Upgrade Governor Contract**
```javascript
// Target: PCEGovernor (proxy)
// Function: upgradeToAndCall(address newImplementation, bytes data)
// Value: 0  
// Calldata: encoded upgrade call
// Note: Governor uses UUPS pattern, controlled by Timelock
```

## Setting Up Governance

### 1. Deploy Contracts
```bash
# Deploy governance:
forge script script/DeployGovernance.s.sol:DeployGovernance --rpc-url $RPC_URL --broadcast

# Transfer ownerships:
forge script script/TransferWPCEOwnership.s.sol:TransferWPCEOwnership --rpc-url $RPC_URL --broadcast
forge script script/TransferPCERoles.s.sol:TransferPCERoles --rpc-url $RPC_URL --broadcast
```

### 2. Start Governance
1. Delegate voting power
2. Create proposals via Governor contract
3. Vote and execute passed proposals

## Best Practices

1. **Delegate Before Voting**: Must delegate to participate
2. **Discussion First**: Use forum/Discord before on-chain proposal
3. **Test on Testnet**: Always test governance actions
4. **Emergency Actions**: Keep multisig for emergencies

## Security Considerations

- Governor can only execute what's proposed
- Timelock prevents rush attacks
- Quorum prevents low-participation attacks
- Upgrade admin should be transferred to Timelock