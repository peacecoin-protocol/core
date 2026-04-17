#!/usr/bin/env bash
# Verify a Tally proposal's calldata for PCE DAO cross-chain governance.
#
# Usage:
#   ./script/verify-proposal.sh <PROPOSAL_ID>
#
# Example:
#   ./script/verify-proposal.sh 105169838359294070465035136878198058523024689968605466559110834911518765392066
#
# Requirements:
#   - cast (foundry)
#   - python3
#   - RPC access to Ethereum mainnet (via ETH_RPC_URL, or the script's default
#     `mainnet` RPC target)
#
# This script:
#   1. Fetches the proposal's on-chain description, targets, values, calldatas
#   2. Verifies the target is the PCE DAO GovernanceSender
#   3. Decodes the sendCrossChainGovernance payload
#   4. Decodes the nested call arguments surfaced by that payload (for example,
#      upgradeTo/upgradeToAndCall) for manual inspection
#   5. Prints a human-readable summary for manual verification

set -euo pipefail

PROPOSAL_ID="${1:?Usage: $0 <PROPOSAL_ID>}"

# PCE DAO known addresses (Production)
GOVERNOR="0x00831a36ce3535EFFeFe54BaD0bb8dE27687a237"
GOVERNANCE_SENDER="0xA197c53c9658C21d4246De66f38012536028B2FB"
EXPECTED_RECEIVER="0x1ea9944aB101e6C5D15896c4012e2bc89B856578"
PCE_TOKEN_PROXY="0xA4807a8C34353A5EA51aF073175950Cb6248dA7E"
CT_BEACON="0x6A73A610707C113F34D8B82498b6868e5f7FAA74"

RPC_URL="${ETH_RPC_URL:-mainnet}"
# PCE Governor was first active at Ethereum block ~23302941 (Sep 2025).
# Override with `FROM_BLOCK=<block>` if the governor is redeployed.
FROM_BLOCK="${FROM_BLOCK:-23302941}"
TO_BLOCK="${TO_BLOCK:-latest}"

echo "=== PCE DAO Proposal Verification ==="
echo "Proposal ID: $PROPOSAL_ID"
echo ""

# --- 1. Fetch on-chain proposal data via ProposalCreated event ---
echo "Fetching ProposalCreated event..."
# Convert PID to uint256/hex form for comparison with the proposalId decoded
# from the first 32 bytes of the event data
PID_HEX=$(cast --to-uint256 "$PROPOSAL_ID")

EVENTS=$(cast logs --rpc-url "$RPC_URL" \
    --address "$GOVERNOR" \
    "ProposalCreated(uint256,address,address[],uint256[],string[],bytes[],uint256,uint256,string)" \
    --from-block "$FROM_BLOCK" --to-block "$TO_BLOCK" --json)

MATCH=$(echo "$EVENTS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
target_hex = '$PID_HEX'
target = int(target_hex, 16)
for log in data:
    raw = bytes.fromhex(log['data'][2:])
    pid = int.from_bytes(raw[:32], 'big')
    if pid == target:
        # Output: tx_hash
        print(log['transactionHash'])
        break
")

if [ -z "$MATCH" ]; then
    echo "ERROR: Proposal not found in ProposalCreated events"
    exit 1
fi

TX_HASH="$MATCH"
echo "Proposal tx: $TX_HASH"

# --- 2. Decode the propose() calldata ---
INPUT=$(cast tx "$TX_HASH" --rpc-url "$RPC_URL" --json | python3 -c "import sys,json; print(json.load(sys.stdin)['input'])")

DECODED=$(cast calldata-decode "propose(address[],uint256[],bytes[],string)" "$INPUT")
echo ""
echo "=== Proposal Actions ==="
echo "$DECODED"
echo ""

# --- 3. Parse proposal target and verify it is the PCE GovernanceSender ---
# The first line of the decoded propose() output is the targets array.
# Since we only support single-action proposals (enforced below), the array
# must contain exactly one address.
TARGETS_LINE=$(echo "$DECODED" | sed -n '1p' | sed 's/^\[//;s/\]$//')
if echo "$TARGETS_LINE" | grep -q ','; then
    echo "ERROR: Multi-action proposals are not supported by this verifier."
    echo "       The targets array contains more than one address: $TARGETS_LINE"
    exit 1
fi
PROPOSAL_TARGET=$(echo "$TARGETS_LINE" | tr -d ' ')
PROPOSAL_TARGET_LOWER=$(echo "$PROPOSAL_TARGET" | tr '[:upper:]' '[:lower:]')
SENDER_LOWER=$(echo "$GOVERNANCE_SENDER" | tr '[:upper:]' '[:lower:]')

if [ "$PROPOSAL_TARGET_LOWER" = "$SENDER_LOWER" ]; then
    echo "✓ Target is GovernanceSender ($GOVERNANCE_SENDER)"
else
    echo "ERROR: Proposal target is NOT the PCE GovernanceSender."
    echo "       Refusing to continue; the decoded inner actions would be misleading."
    echo "       Expected: $GOVERNANCE_SENDER"
    echo "       Got:      $PROPOSAL_TARGET"
    exit 1
fi

# --- 3b. Verify the proposal's target contract's on-chain config ---
# `sendCrossChainGovernance` routes via the target's stored `governanceReceiver`.
# Read the config from the PARSED proposal target (not a hardcoded address) so
# that a malicious target mimicking the selector would still be caught here.
echo ""
echo "=== Proposal target on-chain config ==="
ON_CHAIN_RECEIVER=$(cast call --rpc-url "$RPC_URL" "$PROPOSAL_TARGET" "governanceReceiver()(address)")
echo "  governanceReceiver(): $ON_CHAIN_RECEIVER"
echo "  expected:             $EXPECTED_RECEIVER"
RECEIVER_LOWER=$(echo "$ON_CHAIN_RECEIVER" | tr '[:upper:]' '[:lower:]')
EXPECTED_LOWER=$(echo "$EXPECTED_RECEIVER" | tr '[:upper:]' '[:lower:]')
if [ "$RECEIVER_LOWER" = "$EXPECTED_LOWER" ]; then
    echo "  ✓ receiver matches expected Polygon GovernanceReceiver"
else
    echo "  ERROR: on-chain receiver does NOT match expected address"
    echo "         Refusing to continue because decoded inner actions may be misleading."
    echo "         Expected: $EXPECTED_RECEIVER"
    echo "         Got:      $ON_CHAIN_RECEIVER"
    exit 1
fi

ON_CHAIN_WORMHOLE=$(cast call --rpc-url "$RPC_URL" "$PROPOSAL_TARGET" "WORMHOLE()(address)")
echo "  WORMHOLE():           $ON_CHAIN_WORMHOLE"

# --- 4. Extract outer calldata (the sendCrossChainGovernance call) ---
# The 3rd line of the decoded propose() output is the bytes[] calldatas array.
# This verifier only supports single-action proposals (one sendCrossChainGovernance call).
OUTER_BYTES_LINE=$(echo "$DECODED" | sed -n '3p' | sed 's/^\[//;s/\]$//')
if echo "$OUTER_BYTES_LINE" | grep -q ','; then
    echo "ERROR: Multi-action proposals are not supported by this verifier."
    echo "       This proposal contains more than one action in the outer bytes[]."
    echo "       Please decode each action manually with: cast calldata-decode ..."
    exit 1
fi
OUTER_CALLDATA="$OUTER_BYTES_LINE"
echo ""
echo "=== Outer calldata (sendCrossChainGovernance) ==="
echo "Raw: $OUTER_CALLDATA"
echo ""
echo "Selector check:"
SELECTOR="${OUTER_CALLDATA:0:10}"
echo "  $SELECTOR"
if [ "$SELECTOR" = "0x6f4e17f4" ]; then
    echo "  ✓ sendCrossChainGovernance(address[],uint256[],bytes[],bytes32)"
else
    echo "  ⚠ Unknown selector"
    exit 1
fi

# --- 5. Decode sendCrossChainGovernance args ---
INNER=$(cast calldata-decode "sendCrossChainGovernance(address[],uint256[],bytes[],bytes32)" "$OUTER_CALLDATA")
echo ""
echo "=== Inner actions (will execute on Polygon Timelock) ==="
echo "$INNER"
echo ""

# --- 6. Decode each nested calldata ---
# The inner bytes[] line is the 3rd line
INNER_TARGETS_LINE=$(echo "$INNER" | sed -n '1p' | sed 's/^\[//;s/\]$//')
INNER_BYTES_LINE=$(echo "$INNER" | sed -n '3p' | sed 's/^\[//;s/\]$//')
IFS=',' read -r -a INNER_TARGETS <<< "$INNER_TARGETS_LINE"
IFS=',' read -r -a INNER_CALLDATAS <<< "$INNER_BYTES_LINE"

if [ "${#INNER_TARGETS[@]}" -eq 0 ] || [ -z "${INNER_TARGETS_LINE// /}" ]; then
    echo "Error: decoded inner targets array is empty." >&2
    exit 1
fi

if [ "${#INNER_CALLDATAS[@]}" -eq 0 ] || [ -z "${INNER_BYTES_LINE// /}" ]; then
    echo "Error: decoded inner calldatas array is empty." >&2
    exit 1
fi

if [ "${#INNER_TARGETS[@]}" -ne "${#INNER_CALLDATAS[@]}" ]; then
    echo "Error: decoded inner targets/calldatas length mismatch: ${#INNER_TARGETS[@]} targets vs ${#INNER_CALLDATAS[@]} calldatas." >&2
    exit 1
fi

echo "=== Nested calldata decoding ==="
for i in "${!INNER_CALLDATAS[@]}"; do
    CD=$(echo "${INNER_CALLDATAS[$i]}" | tr -d ' ')
    TGT=$(echo "${INNER_TARGETS[$i]}" | tr -d ' ')
    SEL="${CD:0:10}"
    echo ""
    echo "[$i] target:   $TGT"
    echo "    explorer: https://polygonscan.com/address/$TGT"
    echo "    selector: $SEL"
    case "$SEL" in
        "0x4f1ef286")
            echo "    → upgradeToAndCall(address,bytes)"
            DECODED_ARGS=$(cast calldata-decode "upgradeToAndCall(address,bytes)" "$CD")
            echo "$DECODED_ARGS" | sed 's/^/    /'
            IMPL=$(echo "$DECODED_ARGS" | head -1 | tr -d ' ')
            echo "    new impl: https://polygonscan.com/address/$IMPL#code"
            ;;
        "0x3659cfe6")
            echo "    → upgradeTo(address)"
            IMPL=$(cast calldata-decode "upgradeTo(address)" "$CD" | tr -d ' ')
            echo "    new impl: $IMPL"
            echo "    explorer: https://polygonscan.com/address/$IMPL#code"
            ;;
        "0x54fd4d50")
            echo "    → version() [view function, no-op as tx]"
            ;;
        *)
            echo "    ⚠ Unknown selector. Manual decoding required."
            echo "    Try: cast 4byte $SEL"
            ;;
    esac
done

echo ""
echo "=== Verification checklist ==="
echo "[ ] Target is correct GovernanceSender address"
echo "[ ] GovernanceSender.governanceReceiver() matches expected Polygon receiver"
echo "    - Expected receiver: $EXPECTED_RECEIVER"
echo "[ ] Inner targets (Polygon) are the expected PCE contracts"
echo "    - PCEToken proxy:  $PCE_TOKEN_PROXY"
echo "    - CommunityToken beacon: $CT_BEACON"
echo "[ ] New implementation contracts are verified on Polygonscan"
echo "[ ] Storage layout is compatible: PREV_TAG=<prev> ./script/upgrade.sh script/DeployImpl.s.sol --fork-url polygon"
echo "[ ] Source code of new implementations matches the PR mentioned in the proposal description"
echo ""
echo "Done."
