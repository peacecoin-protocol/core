# PCEToken native meta-transactions

## Sender resolution

PCEToken follows Polygon's native meta-transaction convention. A verified
meta-transaction appends its signer to a self-call. The stateless `ContextMixin`
restores that signer through `_msgSender()`. Direct calls continue to use the
actual caller; arbitrary trailing calldata on a direct call is not trusted.

Bridge deposits still authenticate the actual `polygonChainManager` via
`msg.sender`. Withdrawals burn the balance of `_msgSender()`, including the
signer when a withdrawal is relayed. Existing deposit accounting is unchanged.

Do not add Multicall or any other self-delegatecall path to this context. The
suffix convention is only safe when the self-call's suffix is authenticated by
`NativeMetaTransaction`.

## Legacy domain initialization

Fresh proxies initialize the EIP-712 domain in `initialize()`. An implementation
upgrade does not rerun that initializer. Legacy proxies with a zero
`getDomainSeperator()` must call `initializeNativeMetaTransaction()` through the
proxy's owner. This migration is proxy-only and one-time; it preserves balances,
allowances, nonces, ownership, bridge settings, and community deposit records.

For a legacy proxy, include this migration as the call data of the UUPS
`upgradeToAndCall` action so the implementation switch and domain initialization
are atomic. `Upgrade.s.sol` and `UpgradeDEV.s.sol` select this call only when the
existing domain is zero. For an already initialized proxy, use empty upgrade
call data instead: the migration intentionally rejects a nonzero domain.

Production proposal preparation uses `DeployImpl.s.sol`, which only deploys
implementations and does not upgrade the Timelock-owned proxy. Its next-step
output supplies the migration call data, but the proposal author must select it
based on the proxy's domain at proposal preparation. Include that data in the
proxy's `upgradeToAndCall` action when the domain is zero, not as a separate
later action. Recheck the domain and the unused Polygon initialization flag
before execution. `Upgrade.s.sol` is not an EOA shortcut around governance.

Native meta-transactions fail closed while the domain is zero. Ordinary token
and bridge calls remain available. The initialized domain binds signatures to
the proxy address and Polygon chain ID using the existing Polygon EIP-712 schema.
Clients must obtain the initialized domain and current nonce before signing;
do not reuse signatures made against a legacy zero domain.

Production upgrade actions must be executed through the existing owner/Timelock
governance path. Validate storage compatibility against the deployed baseline
before preparing a governance action. No deployment or governance action is
performed by this change, and no PIP is associated with it.

## Compatibility and validation

- `PCEToken.version()` is `1.0.16`; `PCECommunityToken` is unchanged.
- `ContextMixin` has no storage. Existing Polygon initialization/domain/nonce
  fields and PCEToken fields retain their positions.
- Existing public functions retain their signatures. The migration function and
  malformed-context custom error are additive.
- Regression tests use local ERC1967 proxies and cover signer-scoped transfers,
  approvals, delegated transfers, burns, community creation, owner checks,
  bridge deposits/withdrawals, nonce replay and rollback, direct-call suffix
  isolation, legacy migration, and atomic UUPS upgrades.

For Foundry versions that enforce the production code-size limit on the test
harness itself, run `forge test --code-size-limit 100000`. Existing test harnesses
already exceed 32 KiB because they embed implementation deployment bytecode.
This test-only override does not change the repository's production limit;
check implementation sizes separately with `forge build --sizes`.

Reference: [Polygon ChildERC20](https://github.com/maticnetwork/pos-portal/blob/master/contracts/child/ChildToken/ChildERC20.sol)
and [ContextMixin](https://github.com/maticnetwork/pos-portal/blob/master/contracts/common/ContextMixin.sol).
