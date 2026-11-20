#!/usr/bin/env python3
"""Generate PIP-23 proposal JSON offline; never submit a transaction or read keys.

Usage (Foundry 1.7.1; CAST can explicitly override the cast binary beside FORGE):
  FORGE=/path/to/forge-1.7.1 python3 script/generate_pip23_proposal.py \
    --csv /path/to/distribution_25904711.csv \
    --new-pce 0x<NEW_PROXY> --governor-v2 0x<NEW_IMPLEMENTATION> \
    --description 'PIP-23: New PCE token and distribution' > out/pip23-proposal.json

Add --rpc-url https://ethereum-rpc.publicnode.com for exact deployed-runtime and
owner/supply/closed/ERC1967-slot checks; optionally --rpc-block <NUMBER> pins the block.
Build both profiles first. This rejects swapped addresses, implementations used as
proxies, old V1 implementations and runtime differences. Without --rpc-url it stays offline.

The CSV must match the PIP-23 snapshot SHA-256 below. The input is read-only.
The same generator is invoked by PIP23Fork.t.sol; targets, values, calldatas and
hashes are not independently rebuilt by the rehearsal. Large integers in the JSON
are decimal strings (proposalIdHex is also provided). Values are the integers [0, 0].
This is calldata preparation, not proof of deployment, verification, role exclusivity
or absence of other open proposals. Check PIP-23 Specification 6/7 before proposing.
"""

import argparse
import csv
from decimal import Decimal, InvalidOperation, localcontext
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import urllib.request

GOVERNOR = "0x00831a36ce3535effefe54bad0bb8de27687a237"
TIMELOCK = "0x208983f723245c765b4f9e57faab2633c9ddac6b"
CSV_SHA256 = "0378a93f36b1036c86048e01578ab5879d3e454e51f26ea8c0f6518e80b49f19"
TOTAL_AMOUNT = 222156723489999990835174897
RECIPIENT_COUNT = 138


def address(value):
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", value) or int(value[2:], 16) == 0:
        raise ValueError(f"Invalid nonzero Ethereum address: {value}")
    return value.lower()


def read_distribution(path):
    raw = Path(path).read_bytes()
    reader = csv.DictReader(io.StringIO(raw.decode("utf-8")))
    if reader.fieldnames != ["address", "amount_wei", "amount", "note"]:
        raise ValueError("CSV header must be address,amount_wei,amount,note")
    recipients, amounts = [], []
    for row in reader:
        recipient = address(row["address"])
        if recipient in recipients:
            raise ValueError(f"Duplicate CSV recipient: {recipient}")
        if not re.fullmatch(r"[1-9][0-9]*", row["amount_wei"] or ""):
            raise ValueError(f"Invalid positive integer amount_wei for {recipient}")
        amount = int(row["amount_wei"])
        if amount >= 2**256:
            raise ValueError("amount_wei exceeds uint256")
        with localcontext() as context:
            context.prec = 100
            if Decimal(row["amount"]) * Decimal(10**18) != amount:
                raise ValueError(f"CSV display amount disagrees with amount_wei for {recipient}")
        recipients.append(recipient)
        amounts.append(amount)
    if len(recipients) != RECIPIENT_COUNT or sum(amounts) != TOTAL_AMOUNT:
        raise ValueError("CSV must contain 138 recipients totaling 222156723489999990835174897 wei")
    digest = hashlib.sha256(raw).hexdigest()
    if digest != CSV_SHA256:
        raise ValueError(f"CSV SHA-256 does not match PIP-23: {digest}")
    return recipients, amounts, digest


class Cast:
    def __init__(self):
        configured = os.environ.get("CAST")
        if not configured and os.environ.get("FORGE"):
            forge = shutil.which(os.environ["FORGE"])
            if forge:
                configured = str(Path(forge).resolve().with_name("cast"))
        self.binary = shutil.which(configured or "cast")
        if not self.binary:
            raise ValueError("Cast 1.7.1 not found; set CAST=/absolute/path/to/cast-1.7.1")
        version = self.call("--version").splitlines()[0]
        if version != "cast Version: 1.7.1":
            raise ValueError(f"Cast 1.7.1 is required; got {version!r}. Set CAST=/path/to/cast-1.7.1")

    def call(self, *args):
        result = subprocess.run([self.binary, *args], text=True, capture_output=True, check=False)
        if result.returncode:
            raise ValueError(f"cast failed: {result.stderr.strip()}")
        return result.stdout.strip()

    def checksum(self, value):
        normalized = address(value)
        checksum = self.call("to-check-sum-address", "--", normalized)
        body = value[2:]
        if body != body.lower() and body != body.upper() and checksum != value:
            raise ValueError(f"Invalid EIP-55 checksum: {value}")
        return checksum

    def calldata(self, signature, *args):
        return self.call("calldata", "--", signature, *args)

    def keccak(self, data):
        return self.call("keccak", "--", "0x" + data.hex())


def array(items):
    return "[" + ",".join(str(item) for item in items) + "]"


# RPC validation is optional and read-only. Fresh artifacts from build:pip23 are required.
# It checks code/state, not Etherscan publication or the complete event/role history.
ROOT = Path(__file__).resolve().parents[1]
OLD_IMPLEMENTATION = "0x911c1f527651374ba6546b1f1510832084af5208"
IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"


class RPC:
    def __init__(self, url):
        self.url = url

    def call(self, method, params):
        request = urllib.request.Request(self.url, data=json.dumps({
            "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
        }).encode(), headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=60) as response:
            data = json.load(response)
        if "error" in data or "result" not in data:
            raise ValueError(f"RPC {method} failed")
        return data["result"]


def expected_runtime(artifact_path, target, uups):
    path = ROOT / artifact_path
    if not path.is_file():
        raise ValueError(f"Missing artifact {artifact_path}; run FORGE=/path/to/forge-1.7.1 npm run build:pip23")
    bytecode = json.loads(path.read_text())["deployedBytecode"]
    expected = bytearray.fromhex(bytecode["object"].removeprefix("0x"))
    refs = bytecode.get("immutableReferences", {})
    if uups:
        if len(refs) != 1 or not next(iter(refs.values())):
            raise ValueError("Expected only UUPS __self immutable references")
        for ref in next(iter(refs.values())):
            start, length = ref["start"], ref["length"]
            if length != 32 or start < 0 or start + length > len(expected) or expected[start:start + length] != bytes(32):
                raise ValueError("Invalid UUPS immutable placeholder")
            expected[start:start + length] = bytes.fromhex(address(target)[2:]).rjust(32, b"\0")
    elif refs:
        raise ValueError("Unexpected proxy immutable references")
    return bytes(expected)


def validate_deployments(rpc_url, new_pce, governor_v2, cast, rpc_block=None):
    token, v2 = address(new_pce), address(governor_v2)
    if v2 == OLD_IMPLEMENTATION:
        raise ValueError("Governor V2 must not be the old Governor implementation")
    rpc = RPC(rpc_url)
    if int(rpc.call("eth_chainId", []), 16) != 1:
        raise ValueError("RPC must be Ethereum mainnet (chainId 1)")
    block = hex(rpc_block) if rpc_block is not None else rpc.call("eth_blockNumber", [])

    def runtime(target, path, uups):
        expected = expected_runtime(path, target, uups)
        actual = bytes.fromhex(rpc.call("eth_getCode", [target, block]).removeprefix("0x"))
        if not actual or actual != expected:
            raise ValueError(f"Runtime mismatch for {path} at {target}")

    def word(value):
        if not re.fullmatch(r"0x[0-9a-fA-F]{64}", value):
            raise ValueError("RPC returned an invalid 32-byte word")
        return int(value, 16)

    def storage(slot):
        return word(rpc.call("eth_getStorageAt", [token, slot, block]))

    def call_word(target, signature):
        return word(rpc.call("eth_call", [{"to": target, "data": cast.calldata(signature)}, block]))

    runtime(token, "out/ERC1967Proxy.sol/ERC1967Proxy.json", False)
    if storage(ADMIN_SLOT) != 0:
        raise ValueError("New PCE proxy admin slot must be zero")
    impl = storage(IMPLEMENTATION_SLOT)
    if not 0 < impl < 2**160:
        raise ValueError("Invalid new PCE implementation slot")
    implementation = f"0x{impl:040x}"
    runtime(implementation, "out/PCEMainnetToken.sol/PCEMainnetToken.json", True)
    if call_word(token, "owner()") != int(TIMELOCK, 16):
        raise ValueError("New PCE owner must be Timelock")
    if call_word(token, "totalSupply()") != 0:
        raise ValueError("New PCE totalSupply must be zero")
    if call_word(token, "distributionClosed()") != 0:
        raise ValueError("New PCE distribution must be open")
    runtime(v2, "out-governor-mainnet/PCEGovernorV2.sol/PCEGovernorV2.json", True)
    if call_word(v2, "proxiableUUID()") != int(IMPLEMENTATION_SLOT, 16):
        raise ValueError("Governor V2 must be a UUPS implementation, not a proxy")
    return {"blockNumber": int(block, 16), "tokenImplementation": cast.checksum(implementation),
            "runtimeAndStateChecked": True}


def generate(csv_path, new_pce, governor_v2, description, rpc_url=None, rpc_block=None):
    recipients, amounts, digest = read_distribution(csv_path)
    if not description.strip():
        raise ValueError("description must not be empty")
    token_address, v2_address = address(new_pce), address(governor_v2)
    if token_address == v2_address or {token_address, v2_address} & {GOVERNOR, TIMELOCK}:
        raise ValueError("New PCE and Governor V2 must be distinct new deployment addresses")
    cast = Cast()
    token_address, v2_address = cast.checksum(new_pce), cast.checksum(governor_v2)
    governor = cast.checksum(GOVERNOR)
    distribute = cast.calldata("distribute(address[],uint256[])", array(recipients), array(amounts))
    switch = cast.calldata("switchVotingToken(address)", token_address)
    upgrade = cast.calldata("upgradeToAndCall(address,bytes)", v2_address, switch)
    targets, values, calldatas = [token_address, governor], [0, 0], [distribute, upgrade]
    description_hash = cast.keccak(description.encode("utf-8"))
    encoded = cast.call("abi-encode", "--", "f(address[],uint256[],bytes[],bytes32)",
                        array(targets), array(values), array(calldatas), description_hash)
    proposal_id_hex = cast.keccak(bytes.fromhex(encoded.removeprefix("0x")))
    # bytes and string have identical ABI layouts. Encode raw UTF-8 bytes because cast's
    # string argument parser trims trailing whitespace; description hashes must preserve it.
    propose_args = cast.call("abi-encode", "--", "f(address[],uint256[],bytes[],bytes)",
                             array(targets), array(values), array(calldatas),
                             "0x" + description.encode("utf-8").hex())
    propose = cast.call("sig", "--", "propose(address[],uint256[],bytes[],string)") + propose_args[2:]
    result = {
        "schema": "pip-23-proposal-v1", "chainId": 1, "governor": governor,
        "newPCE": token_address, "governorV2": v2_address,
        "targets": targets, "values": values, "calldatas": calldatas,
        "description": description, "descriptionHash": description_hash,
        "proposalId": str(int(proposal_id_hex, 16)), "proposalIdHex": proposal_id_hex,
        "proposeCalldata": propose,
        "distribution": {"csvSha256": digest, "recipientCount": len(recipients),
                         "totalAmountWei": str(sum(amounts))},
    }
    if rpc_url:
        result["rpcValidation"] = validate_deployments(rpc_url, token_address, v2_address, cast, rpc_block)
    elif rpc_block is not None:
        raise ValueError("--rpc-block requires --rpc-url")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--csv", required=True, type=Path)
    parser.add_argument("--new-pce", required=True)
    parser.add_argument("--governor-v2", required=True)
    parser.add_argument("--description", required=True)
    parser.add_argument("--rpc-url", help="Optional read-only mainnet runtime/state validation (requires build:pip23)")
    parser.add_argument("--rpc-block", type=int, help="Validate at this block; otherwise pin the current RPC block")
    args = parser.parse_args()
    if args.rpc_block is not None and args.rpc_block < 0:
        parser.error("--rpc-block must not be negative")
    try:
        data = generate(args.csv, args.new_pce, args.governor_v2, args.description, args.rpc_url, args.rpc_block)
    except (OSError, ValueError, InvalidOperation, KeyError, TypeError) as error:
        parser.exit(2, f"PIP-23 proposal: {error}\n")
    print(json.dumps(data, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
