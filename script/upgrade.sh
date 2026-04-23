#!/usr/bin/env bash
set -euo pipefail

# Usage: ./script/upgrade.sh <FORGE_SCRIPT> [FORGE_ARGS...]
# Example: ./script/upgrade.sh script/UpgradeDEV.s.sol --broadcast --fork-url polygon
#
# The previous version tag is auto-detected from the latest git tag.
# To override: PREV_TAG=v10 ./script/upgrade.sh script/UpgradeDEV.s.sol --broadcast --fork-url polygon

SCRIPT="${1:?Usage: $0 <FORGE_SCRIPT> [FORGE_ARGS...]}"
shift 1

PREV_TAG="${PREV_TAG:-$(git describe --tags --abbrev=0 2>/dev/null)}"
if [ -z "$PREV_TAG" ]; then
    echo "ERROR: No git tags found. Tag the current deployed version first: git tag v11"
    exit 1
fi

WORKTREE_DIR=".upgrade-reference-build"
REF_BUILD_INFO="/tmp/oz-upgrade-ref-build-info-$$"

cleanup() {
    git worktree remove --force "$WORKTREE_DIR" 2>/dev/null || true
    rm -rf "$REF_BUILD_INFO"
}
trap cleanup EXIT

# Step 1: Build previous version from git tag
echo "==> Building previous version from tag: $PREV_TAG"
git worktree add --detach "$WORKTREE_DIR" "$PREV_TAG" 2>/dev/null
(cd "$WORKTREE_DIR" && forge build --skip test --skip script 2>&1) | tail -3

# Copy build-info to a temp dir with a unique name (OZ requires unique dir short names)
mkdir -p "$REF_BUILD_INFO"
cp "$WORKTREE_DIR/out/build-info/"*.json "$REF_BUILD_INFO/"
git worktree remove --force "$WORKTREE_DIR" 2>/dev/null

# Step 2: Build current version
echo "==> Building current version"
forge clean
forge build

# Step 3: Validate storage layout compatibility
echo "==> Validating upgrade safety (storage layout check)"
REF_DIR_NAME="$(basename "$REF_BUILD_INFO")"
ERRORS=0

validate_contract() {
    local contract="$1"
    local candidates="$2"
    # `unsafe_allow_linked_libraries` is off by default so unintended external
    # library linkage in future upgrades is still caught. Set it per-contract
    # below only for contracts we deliberately link libraries into.
    local unsafe_allow_linked_libraries="${3:-0}"

    local extra_args=()
    if [ "$unsafe_allow_linked_libraries" = "1" ]; then
        extra_args+=("--unsafeAllow" "external-library-linking")
    fi

    for candidate in $candidates; do
        if npx @openzeppelin/upgrades-core@^1.32.3 validate out/build-info \
            --contract "$contract" \
            --reference "$REF_DIR_NAME:$candidate" \
            --referenceBuildInfoDirs "$REF_BUILD_INFO" \
            "${extra_args[@]}" 2>/dev/null; then
            echo "  $contract: OK (reference: $candidate)"
            return 0
        fi
    done
    echo "  $contract: FAILED"
    return 1
}

# Try matching reference contract names.
# Versioned filenames (V20..V1) are tried first, then the consolidated filename.
# This ensures we compare against the latest version at that tag, not the V1 original.
# Pre-consolidation versions used both versioned contract names (PCETokenVN) and filenames.
PCE_CANDIDATES=""
for v in $(seq 20 -1 1); do
    PCE_CANDIDATES="$PCE_CANDIDATES src/PCETokenV${v}.sol:PCETokenV${v}"
    PCE_CANDIDATES="$PCE_CANDIDATES src/PCETokenV${v}.sol:PCEToken"
done
PCE_CANDIDATES="$PCE_CANDIDATES src/PCEToken.sol:PCEToken"

COMMUNITY_CANDIDATES=""
for v in $(seq 20 -1 1); do
    COMMUNITY_CANDIDATES="$COMMUNITY_CANDIDATES src/PCECommunityTokenV${v}.sol:PCECommunityTokenV${v}"
    COMMUNITY_CANDIDATES="$COMMUNITY_CANDIDATES src/PCECommunityTokenV${v}.sol:PCECommunityToken"
done
COMMUNITY_CANDIDATES="$COMMUNITY_CANDIDATES src/PCECommunityToken.sol:PCECommunityToken"

validate_contract "src/PCEToken.sol:PCEToken" "$PCE_CANDIDATES" || ERRORS=1
# PCECommunityToken legitimately links VoucherSystem/TokenValueOps/ArigatoCreation
# (external libraries) since v15 — allow the OZ validator to accept that.
validate_contract "src/PCECommunityToken.sol:PCECommunityToken" "$COMMUNITY_CANDIDATES" 1 || ERRORS=1

if [ "$ERRORS" -ne 0 ]; then
    echo "ERROR: Storage layout validation failed. Aborting upgrade."
    exit 1
fi

# Step 4: Run forge script (skip OZ's built-in check since we already validated)
echo "==> Running forge script"
FOUNDRY_UPGRADES_UNSAFE_SKIP_STORAGE_CHECK=true forge script "$SCRIPT" "$@"
