# Changelog

All notable changes to the PCEToken and PCECommunityToken contracts are documented here.
Version numbering was previously tracked via separate contract files (e.g., PCETokenV2.sol).
As of v11, a single file per contract is used and versioning is managed through git history.

## v11
- Add daily swap-to-PCE tracking to prevent limit bypass (global and individual)
- Replace `burnFrom` with `burnByPCEToken` in `swapFromLocalToken` (no user approval needed)
- Add `recordSwapToPCE`, `getRemainingSwapableToPCEBalance`, `getRemainingSwapableToPCEBalanceForIndividual`
- Remove console2.log from production code
- Consolidate versioned files into single PCEToken.sol / PCECommunityToken.sol

## v10
- Fix `swapFromLocalToken` with daily global/individual swap caps
- Switch to Wednesday-based weekly depreciation (from minute-based)
- Add `swapableToPCERate` and `swapableToPCEIndividualRate` settings
- Use `Math.mulDiv` for safer arithmetic in swap calculations

## v9
- Add VoucherSystem integration (Merkle tree-based voucher claim)
- Add `claimVoucherWithAuthorization` for meta-transaction voucher claims
- Add voucher management functions (register, claim, add/withdraw funds, terminate)

## v8
- Add `getSwapRateBetweenTokens` for cross-community-token exchange rates
- Add `getMetaTransactionFeeWithBaseFee` function

## v7
- Version bump (no functional changes)

## v6
- Version bump (no functional changes)

## v5
- Add meta-transaction support (EIP-3009 `transferWithAuthorization`)
- Add `transferFromWithAuthorization` for spender-signed meta-transactions
- Add infinity approve flag (`setInfinityApproveFlag`, `setInfinityApproveFlagWithAuthorization`)
- Add meta-transaction fee collection mechanism

## v4
- Add factor decrease mechanism (Wednesday-based weekly depreciation)
- Add `isWednesdayBetween` utility function

## v3
- Add exchange rate calculation between community tokens (`swapTokens`)

## v2
- Fix overflow issues in community token operations
- Add community token swap functionality (`swapToLocalToken`, `swapFromLocalToken`)

## v1
- Initial implementation
- UUPS proxy pattern for PCEToken
- Beacon proxy pattern for PCECommunityToken
- Basic ERC20 with factor-based value depreciation
- Community token creation via `createToken`
- Polygon bridge support (deposit/withdraw)
- Native meta-transaction support
