#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$ROOT"

fail() {
    printf 'PIP-23: %s\n' "$*" >&2
    exit 1
}

mode=${1:-}
if (($#)); then shift; fi
case "$mode" in
    build-governor|build|test-pip23)
        (($# == 0)) || fail "Unexpected arguments for $mode"
        ;;
    test) ;; # Forward normal test arguments, e.g. --code-size-limit for large legacy test harnesses.
    *) fail "Usage: bash script/pip23.sh {build-governor|build|test|test-pip23} [test arguments]" ;;
esac

# Reject configuration overrides without inspecting their values (which may be sensitive).
# FOUNDRY_PROFILE is harmless here: every Forge invocation sets it explicitly.
while IFS= read -r name; do
    case "$name" in
        FOUNDRY_PROFILE) ;;
        FOUNDRY_*|DAPP_*) fail "Build configuration override is not allowed: $name. Unset it before running PIP-23 commands." ;;
    esac
done < <(compgen -e)

# Fail before doing any build work: the release rehearsal must never silently skip the fork.
rpc=${FORK_RPC_URL:-}
if [[ "$mode" == test-pip23 && -z "${rpc//[[:space:]]/}" ]]; then
    fail "FORK_RPC_URL is required for test:pip23 (for example https://ethereum-rpc.publicnode.com)"
fi

FORGE=${FORGE:-forge}
command -v "$FORGE" >/dev/null 2>&1 || fail "Forge not found: $FORGE. Set FORGE=/absolute/path/to/forge-1.7.1"
version=$("$FORGE" --version) || fail "Could not read Forge version: $FORGE"
[[ "${version%%$'\n'*}" == 'forge Version: 1.7.1' ]] ||
    fail "Forge 1.7.1 is required; got '${version%%$'\n'*}'. Set FORGE=/absolute/path/to/forge-1.7.1"

build_governor() {
    FOUNDRY_PROFILE=governor_mainnet "$FORGE" build --force
}

build_all() {
    build_governor
    # upgrades-core must see exactly one complete compiler input, never old incremental build-info.
    rm -rf -- "$ROOT/out/build-info"
    FOUNDRY_PROFILE=default "$FORGE" build --force
}

case "$mode" in
    build-governor) build_governor ;;
    build) build_all ;;
    test)
        build_all
        FOUNDRY_PROFILE=default "$FORGE" test "$@"
        ;;
    test-pip23)
        build_all
        python3 -B script/verify_mainnet_governor.py --rpc-url "$rpc"
        FOUNDRY_PROFILE=governor_mainnet "$FORGE" test -vv
        FOUNDRY_PROFILE=default "$FORGE" test --match-contract \
            '^(PCEMainnetTokenTest|PCEGovernorV2Test|PIP23UpgradeValidationTest|PIP23ArtifactPreflightTest|PIP23DeploymentTest|PIP23DeploymentChecksTest)$' -vv
        FOUNDRY_PROFILE=default "$FORGE" test --isolate --match-path test/PIP23Fork.t.sol -vv
        ;;
esac
