# Security findings follow-up

This change builds on the NativeMetaTransaction sender fix in PR #47. It does not deploy, upgrade, submit governance proposals, create a PIP, or change Security Cloud finding statuses.

## Finding dispositions

| Finding | Disposition |
| --- | --- |
| Native meta-transaction sender/context mismatch (`9daa7eb83ea08191ae5a0552f4b069cc`) | Addressed by prerequisite PR #47. |
| Fee conversion with zero/rounded raw burn (`36164fa4e66c819188626edfe415741a`) | Positive fees are converted to raw burn quantities with ceiling rounding. PCE conversion uses the full configured display fee, never the rounding surplus. |
| Legacy absolute-quorum upgrade (`8a56de05dbf08191b58ea6d3b342c6bc`) | Excluded by user decision: the deployed Governor already has configured absolute quorum. The claimed inherited-storage shift is not applicable to the pinned OZ 5 ERC-7201 namespaces. No Governor source change. |
| Fee swaps exempt from ordinary daily swap limits (`a766604902fc8191b8e2e32955728a0d`) | **Intentional specification**, confirmed by the user. Fee swaps are exempt; limits and fee ABI are unchanged. |
| GovernanceReceiver delivery-order dependency (`7eac813202d881919535bbf09f97d7bc`) | Authenticate the emitter and track each emitter/sequence independently. Out-of-order delivery is supported. |
| Deprecated treasury allowance flow (`3733b638298481919122a34bc3d39eb5`) | Already absent from current executable code. Deprecated storage remains for layout compatibility; no restoration or storage removal. |
| Zero-address Timelock proposer (`46d2bdd710b48191a4dcf5ee4265d9ed`) | The reported open-role scheduling premise is false for the pinned dependency. `schedule`/`scheduleBatch` use `onlyRole(PROPOSER_ROLE)`. Only execution uses `onlyRoleOrOpenRole(EXECUTOR_ROLE)`. |

These are source-level dispositions, not evidence that no incident occurred. No attack reproduction, vulnerable-implementation execution, or mainnet-fork test is included.

## Fee settlement compatibility

Zero configured fees remain valid. Positive fees use ceiling rounding at both inverse raw/display conversion stages so the raw tokens burned cover the configured fee. The relayer's PCE conversion uses the configured display fee, not the ceiling surplus. Normal transfer rounding is unchanged. Voucher claims use the same ceiling-rounded raw fee for withholding and burning; the old positive-dust waiver is removed. Claims whose raw amount is not greater than the raw fee fail atomically. `MetaTransactionFeeCollected.displayFee` and `MetaTransactionFeeSwapped.communityTokenFee` report the configured display fee; `rawFee` reports the ceiling-rounded burn.

The existing three-argument `swapFeeFromLocalToken` ABI and daily-limit exemption are intentional, confirmed by the user. Fee conversion is not an ordinary user swap and must not consume ordinary community or personal daily allowances. This exception supports paid voucher onboarding even when a new recipient has no previous-midnight individual allowance. It is not classified as pending or fixed by changing limits. `displayFeeToRawBalance` is an additive view ABI used by the linked VoucherSystem library; deploy the updated library with the updated community implementation.

Community implementation version: `1.0.18`. PCEToken version is unchanged from PR #47 (`1.0.16`). Deployments must retain that prerequisite's sender and legacy-domain protections.

## Governor finding: excluded from this change

The reported inherited-storage shift does not apply to the pinned OZ 5 ERC-7201 namespaces. Read-only Ethereum verification at block 26109851 (2026-10-03 05:54:59 UTC) returned `500000 ether` from both `absoluteQuorum()` and `quorum(0)` on the configured Governor proxy, with implementation `0x911c1f527651374ba6546b1f1510832084af5208`. The current deployment has already completed the transition to configured absolute quorum. The user explicitly excluded old percentage-to-absolute migration support and its tests/fixture from this security batch. Governor source is unchanged from the prerequisite branch. This does not claim immunity from unrelated future implementation defects.

## GovernanceReceiver replacement

The current Receiver is a non-proxy, constructor-based contract with immutable Wormhole and Timelock references. This source repair does **not** update the deployed Receiver. Deployment requires separate authorization and a coordinated replacement plan:

- Deploy/configure a new Receiver with the correct Wormhole, Timelock, owner, emitter and guardian.
- Coordinate the Ethereum GovernanceSender destination change with Polygon Timelock proposer/canceller role changes. Revoke the old Receiver's scheduling authority and grant it to the new Receiver through the normal authorized governance paths.
- Inventory already-emitted VAAs and pending Timelock operations before switching. VAAs include the receiver destination and cannot simply be redirected. Drain/cancel/reissue applicable old messages under an explicitly approved cutover plan.
- The two chains are not atomically upgradeable. Do not switch either side without checking pending operations, role configuration, and the recovery path.

`processedMessages(emitter, sequence)` is the replay authority. The old `nextMinimumSequence()` getter is retained only as a saturated high-water mark, not an acceptance threshold. Changing the configured sender gives the new emitter an independent sequence space; switching back does not erase the old emitter's replay state. Failed scheduling reverts replay state, and a maximum uint64 sequence does not block lower, unprocessed messages.

## Validation

Run `forge test --code-size-limit 100000` on this host's old Foundry runner. The override is test-only for existing oversized test harnesses; production `foundry.toml` remains at 32768. Use full build-info snapshots for OpenZeppelin validation so concurrent/incremental test compilation cannot replace the validation input. Verified deployed community sources remain the production storage reference. Re-run strict OpenZeppelin validation against the main baseline and deployed community build-info. No storage-layout bypass is permitted.
