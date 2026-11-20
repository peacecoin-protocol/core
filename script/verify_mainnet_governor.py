#!/usr/bin/env python3
"""Compare the production Governor runtime, masking only compiler-reported UUPS __self."""

import argparse
import hashlib
import json
from pathlib import Path
import urllib.request

# The checks below use assert; refuse to run when Python strips them (-O or PYTHONOPTIMIZE).
if not __debug__:
    raise SystemExit("verify_mainnet_governor.py must not run with python -O or PYTHONOPTIMIZE")

ROOT = Path(__file__).resolve().parents[1]
IMPLEMENTATION = "0x911c1f527651374ba6546b1f1510832084af5208"


def read_artifact(path):
    artifact = json.loads(path.read_text())
    metadata = artifact["metadata"]
    if isinstance(metadata, str):
        metadata = json.loads(metadata)
    assert metadata["compiler"]["version"] == "0.8.26+commit.8a97fa7a"
    settings = metadata["settings"]
    assert settings["optimizer"] == {"enabled": True, "runs": 10000}
    assert settings["evmVersion"] == "shanghai" and settings["viaIR"]
    assert settings["metadata"]["bytecodeHash"] == "none"
    assert settings["metadata"].get("appendCBOR", True)
    assert not settings["metadata"].get("useLiteralContent", False)
    return artifact


def check_only_migration_added(reference, v2):
    def abi_set(artifact):
        return {json.dumps(item, sort_keys=True) for item in artifact["abi"] if item["type"] != "constructor"}

    before, after = abi_set(reference), abi_set(v2)
    assert not before - after, "V2 removed or changed existing ABI entries"
    additions = [json.loads(item) for item in after - before]
    assert {(item["type"], item["name"]) for item in additions} == {
        ("function", "switchVotingToken"),
        ("event", "VotingTokenSwitched"),
        ("error", "InvalidVotingToken"),
    }
    assert len(additions) == 3
    contract = next(node for node in v2["ast"]["nodes"] if node.get("name") == "PCEGovernorV2")
    assert {node["nodeType"] for node in contract["nodes"]} == {
        "ErrorDefinition", "EventDefinition", "FunctionDefinition", "ModifierDefinition"
    }
    assert [node["name"] for node in contract["nodes"] if node["nodeType"] == "FunctionDefinition"] == [
        "switchVotingToken"
    ]
    assert [node["name"] for node in contract["nodes"] if node["nodeType"] == "ModifierDefinition"] == [
        "onlyMigrationExecutor"
    ]
    # Solc's type IDs contain source AST IDs; compare storage positions and types, not those IDs.
    def layout(artifact):
        data = artifact["storageLayout"]
        return [(item["label"], item["slot"], item["offset"], data["types"][item["type"]]["label"])
                for item in data["storage"]]

    assert layout(reference) == layout(v2)
    print("V2: existing ABI/storage unchanged; only switchVotingToken, VotingTokenSwitched, InvalidVotingToken added")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc-url", default="https://ethereum-rpc.publicnode.com")
    parser.add_argument("--artifact", type=Path,
                        default=ROOT / "out-governor-mainnet/PCEGovernor.sol/PCEGovernor.json")
    parser.add_argument("--v2-artifact", type=Path,
                        default=ROOT / "out-governor-mainnet/PCEGovernorV2.sol/PCEGovernorV2.json")
    parser.add_argument("--reference-only", action="store_true", help="Skip V2 ABI/storage comparison")
    args = parser.parse_args()
    artifact = read_artifact(args.artifact)
    if not args.reference_only:
        check_only_migration_added(artifact, read_artifact(args.v2_artifact))
    request = urllib.request.Request(args.rpc_url, data=json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "eth_getCode", "params": [IMPLEMENTATION, "latest"]
    }).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        result = json.load(response)
    if "error" in result:
        raise RuntimeError(result["error"])
    actual = bytearray.fromhex(result["result"].removeprefix("0x"))
    bytecode = artifact["deployedBytecode"]
    expected = bytearray.fromhex(bytecode["object"].removeprefix("0x"))
    assert len(actual) == len(expected), (
        f"Runtime size mismatch: production={len(actual)} bytes, local={len(expected)} bytes"
    )
    refs = bytecode["immutableReferences"]
    assert len(refs) == 1, "Expected only one immutable: UUPS __self"
    self_value = bytes.fromhex(IMPLEMENTATION.removeprefix("0x")).rjust(32, b"\0")
    for item in next(iter(refs.values())):
        start, length = item["start"], item["length"]
        assert length == 32
        assert actual[start:start + length] == self_value, "Masked production value must equal __self"
        assert expected[start:start + length] == bytes(32), "Expected a solc immutable placeholder"
        actual[start:start + length] = bytes(length)
    assert actual == expected, (
        f"Runtime mismatch: production={len(actual)} bytes, local={len(expected)} bytes"
    )
    print(f"MATCH: {IMPLEMENTATION}, {len(actual)} bytes; UUPS __self offsets "
          f"{[item['start'] for item in next(iter(refs.values()))]}")
    print(f"Normalized runtime SHA-256: {hashlib.sha256(actual).hexdigest()}")


if __name__ == "__main__":
    main()
