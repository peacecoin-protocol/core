#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# Determine target: dev or prd
TARGET="${1:-dev}"

if [ "$TARGET" = "dev" ]; then
    FORGE_SCRIPT="script/UpgradeDEV.s.sol"
    echo "=== Deploying to DEV (Polygon mainnet) ==="
elif [ "$TARGET" = "prd" ]; then
    FORGE_SCRIPT="script/Upgrade.s.sol"
    echo "=== Deploying to PRD (Polygon mainnet) ==="
else
    echo "Usage: $0 [dev|prd]"
    exit 1
fi

echo "=== Stripping console2 from src/ for deployment ==="

FILES=$(grep -rl 'console2' src/ || true)

if [ -z "$FILES" ]; then
    echo "  No console2 usage found in src/"
else
    for f in $FILES; do
        echo "  Stripping: $f"
        perl -0777 -i -pe '
            s/^\s*import\s*\{?\s*console2\s*\}?\s*from\s*"[^"]*";\s*\n//gm;
            s/^\s*console2\.log\([^;]*\);\s*\n//gm;
            s/^\s*\/\/.*console2.*\n//gm;
        ' "$f"
    done
fi

echo "=== Building ==="
forge clean && forge build

source .env

echo "=== Deploying $FORGE_SCRIPT ==="
forge script "$FORGE_SCRIPT" \
    --broadcast \
    --fork-url polygon \
    --interactives 1 \
    --code-size-limit 49152 \
    --verify \
    --etherscan-api-key "$API_KEY_POLYGONSCAN"

echo "=== Restoring original source files ==="
git checkout src/

echo "=== Done ==="
