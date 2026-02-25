#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

echo "=== Stripping console2 from src/ for deployment ==="

FILES=$(grep -rl 'console2' src/ || true)

if [ -z "$FILES" ]; then
    echo "No console2 usage found in src/"
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

echo "=== Deploying UpgradeDEV ==="
source .env
forge script script/UpgradeDEV.s.sol --broadcast --fork-url polygon --interactives 1 --code-size-limit 49152

echo "=== Restoring original source files ==="
git checkout src/

echo "=== Done ==="
