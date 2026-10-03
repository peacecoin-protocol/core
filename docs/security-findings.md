# Security findings follow-up

This change builds on the NativeMetaTransaction sender fix in PR #47. It does not deploy, upgrade, submit governance proposals, create a PIP, or change Security Cloud finding statuses.

## Finding dispositions

| Finding | Disposition |
| --- | --- |
| Native meta-transaction sender/context mismatch (`9daa7eb83ea08191ae5a0552f4b069cc`) | Addressed by prerequisite PR #47. |
| Fee conversion with zero/rounded raw burn (`36164fa4e66c819188626edfe415741a`) | The shared fee helper rejects nonzero fees with no representable raw/display value. PCE conversion uses only the display value represented by the raw tokens burned. |
| Legacy absolute-quorum upgrade (`8a56de05dbf08191b58ea6d3b342c6bc`) | Add atomic, timelock-only migration and reject unconfigured quorum. The claimed inherited-storage shift is not applicable to the pinned OZ 5 ERC-7201 namespaces. |
| Fee swaps exempt from ordinary daily swap limits (`a766604902fc8191b8e2e32955728a0d`) | **Pending specification**, by explicit user decision. Limits and fee ABI are unchanged. |
| GovernanceReceiver delivery-order dependency (`7eac813202d881919535bbf09f97d7bc`) | Authenticate the emitter and track each emitter/sequence independently. Out-of-order delivery is supported. |
| Deprecated treasury allowance flow (`3733b638298481919122a34bc3d39eb5`) | Already absent from current executable code. Deprecated storage remains for layout compatibility; no restoration or storage removal. |
| Zero-address Timelock proposer (`46d2bdd710b48191a4dcf5ee4265d9ed`) | The reported open-role scheduling premise is false for the pinned dependency. `schedule`/`scheduleBatch` use `onlyRole(PROPOSER_ROLE)`. Only execution uses `onlyRoleOrOpenRole(EXECUTOR_ROLE)`. |

These are source-level dispositions, not evidence that no incident occurred. No attack reproduction, vulnerable-implementation execution, or mainnet-fork test is included.

## Fee settlement compatibility

Zero configured fees remain valid. A positive fee passed to the shared fee helper that cannot be represented after raw/display rounding fails atomically instead of paying from the reserve without the corresponding burn. Voucher authorization claims retain their existing `rawFee == 0` waiver: the claim succeeds without any fee burn or PCE payout. `MetaTransactionFeeCollected.displayFee` and `MetaTransactionFeeSwapped.communityTokenFee` now report the effective, rounded display amount; clients must not assume it equals the requested fee exactly.

The existing three-argument `swapFeeFromLocalToken` ABI and the current daily-limit exemption remain unchanged. Daily limits need a separate specification covering the payer, fee budget, and new voucher recipients. In particular, a new recipient can have no previous-midnight individual swap allowance; applying the ordinary personal limit would block paid voucher onboarding. This pending item is not resolved by the rounding fix.

Community implementation version: `1.0.18`. PCEToken version is unchanged from PR #47 (`1.0.16`). Deployments must retain that prerequisite's sender and legacy-domain protections.

## Governor upgrade compatibility

The percentage-quorum implementation at the historical pre-absolute-quorum revision stores quorum history in an OZ ERC-7201 namespace. Removing that base does not shift the GovernorVotes/Timelock namespaces or the three root setting slots. The added absolute-quorum slots nevertheless need explicit initialization when migrating such a legacy proxy. The deprecated quorum-history namespace struct is retained explicitly, even though it is no longer read, so strict OpenZeppelin validation accepts the legacy layout without suppressing deleted-namespace checks.

For a **verified percentage-quorum proxy only**, include
`abi.encodeCall(PCEGovernor.initializeAbsoluteQuorum, (approvedQuorumToken, approvedPositiveQuorum))`
in the Timelock's `upgradeToAndCall` data. The method is proxy-only, Timelock-only, one-time, and rejects zero configuration. The authorization intentionally matches `_authorizeUpgrade`: `onlyGovernance` would additionally require the nested initializer calldata to be registered in the Governor execution deque, whereas the registered governance action is the outer upgrade call.

Do not perform an empty-data legacy upgrade followed by a separate migration. `quorum()` rejects an unconfigured absolute quorum; it cannot silently treat zero as an acceptable threshold. If the Timelock has no independent proposer, an empty-data legacy upgrade can leave no recovery path through Governor because unconfigured quorum also blocks proposal state evaluation. Local tests include actual proposal/vote/queue/Timelock execution of the atomic migration and preservation of existing settings and historical quorum storage.

Read-only Ethereum verification at block `0x18e6444` found the configured Governor proxy already returning `500000 ether` for `absoluteQuorum()` and pointing to the expected Timelock. Its verified implementation is `0x911c1f527651374ba6546b1f1510832084af5208` (Solidity 0.8.26). **Do not call this legacy migration on the already-configured deployment.** Fresh initialization and ordinary upgrades of that deployment preserve its existing quorum. Recheck implementation and configuration before any future authorized execution.

## GovernanceReceiver replacement

The current Receiver is a non-proxy, constructor-based contract with immutable Wormhole and Timelock references. This source repair does **not** update the deployed Receiver. Deployment requires separate authorization and a coordinated replacement plan:

- Deploy/configure a new Receiver with the correct Wormhole, Timelock, owner, emitter and guardian.
- Coordinate the Ethereum GovernanceSender destination change with Polygon Timelock proposer/canceller role changes. Revoke the old Receiver's scheduling authority and grant it to the new Receiver through the normal authorized governance paths.
- Inventory already-emitted VAAs and pending Timelock operations before switching. VAAs include the receiver destination and cannot simply be redirected. Drain/cancel/reissue applicable old messages under an explicitly approved cutover plan.
- The two chains are not atomically upgradeable. Do not switch either side without checking pending operations, role configuration, and the recovery path.

`processedMessages(emitter, sequence)` is the replay authority. The old `nextMinimumSequence()` getter is retained only as a saturated high-water mark, not an acceptance threshold. Changing the configured sender gives the new emitter an independent sequence space; switching back does not erase the old emitter's replay state. Failed scheduling reverts replay state, and a maximum uint64 sequence does not block lower, unprocessed messages.

## Validation

Run `forge test --code-size-limit 100000` on this host's old Foundry runner. The override is test-only for existing oversized test harnesses; production `foundry.toml` remains at 32768. Use full build-info snapshots for OpenZeppelin validation so concurrent/incremental test compilation cannot replace the validation input. The legacy percentage-quorum fixture is derived from the historical source and adapted only to compile with the pinned compiler/dependencies; it is a migration-state fixture, not a claim of byte-for-byte deployed equivalence. Verified deployed Governor and community sources are compiled separately for production layout validation. The production community implementation read at Polygon block `0x5a77960` is `0xc4ac6e2a3c116ecffa4a3a461ffeb378c5def8cd`; its verified community source matches the main baseline exactly.
