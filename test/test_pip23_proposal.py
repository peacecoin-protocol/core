"""Offline proposal-generator checks; use CAST=.../cast-1.7.1 or FORGE=.../forge."""

import csv
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("pip23_proposal", ROOT / "script/generate_pip23_proposal.py")
PROPOSAL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROPOSAL)
CSV = ROOT / "test/fixtures/distribution_25904711.csv"
TOKEN = "0x1111111111111111111111111111111111111111"
V2 = "0x2222222222222222222222222222222222222222"


def uint(data, offset):
    return int.from_bytes(data[offset:offset + 32], "big")


def dynamic(data, head_offset):
    offset = uint(data, head_offset)
    return data[offset + 32:offset + 32 + uint(data, offset)]


class PIP23ProposalTest(unittest.TestCase):
    def setUp(self):
        (ROOT / "cache").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="pip23-proposal-", dir=ROOT / "cache")
        self.addCleanup(self.temp.cleanup)

    def changed_csv(self, change):
        rows = list(csv.DictReader(io.StringIO(CSV.read_text())))
        change(rows)
        path = Path(self.temp.name) / "changed.csv"
        with path.open("w", newline="") as file:
            writer = csv.DictWriter(file, fieldnames=["address", "amount_wei", "amount", "note"], lineterminator="\n")
            writer.writeheader()
            writer.writerows(rows)
        return path

    def test_exact_csv_and_action_encoding(self):
        recipients, amounts, digest = PROPOSAL.read_distribution(CSV)
        data = PROPOSAL.generate(CSV, TOKEN, V2, "PIP-23 test")
        self.assertEqual(data["distribution"]["csvSha256"], digest)
        self.assertEqual(data["distribution"]["recipientCount"], 138)
        self.assertEqual(int(data["distribution"]["totalAmountWei"]), sum(amounts))
        self.assertEqual([value.lower() for value in data["targets"]], [TOKEN, PROPOSAL.GOVERNOR])
        self.assertEqual(data["values"], [0, 0])
        self.assertEqual(int(data["proposalId"]), int(data["proposalIdHex"], 16))
        self.assertEqual(data["chainId"], 1)
        encoded = bytes.fromhex(data["calldatas"][0][10:])
        addresses_at, amounts_at = uint(encoded, 0), uint(encoded, 32)
        self.assertEqual(uint(encoded, addresses_at), 138)
        self.assertEqual(uint(encoded, amounts_at), 138)
        for i in range(138):
            word = encoded[addresses_at + 32 * (i + 1):addresses_at + 32 * (i + 2)]
            self.assertEqual("0x" + word[-20:].hex(), recipients[i])
            self.assertEqual(uint(encoded, amounts_at + 32 * (i + 1)), amounts[i])
        upgrade = bytes.fromhex(data["calldatas"][1][10:])
        self.assertEqual("0x" + upgrade[12:32].hex(), V2)
        switch = dynamic(upgrade, 32)
        self.assertEqual(len(switch), 36)
        self.assertEqual("0x" + switch[-20:].hex(), TOKEN)

    def test_description_bytes_are_preserved(self):
        for description in ("0x1234", "--flag", "  PIP-23  ", "日本語の提案\nsecond line\n", 'quote "yes" \\ backslash'):
            with self.subTest(description=description):
                data = PROPOSAL.generate(CSV, TOKEN, V2, description)
                body = bytes.fromhex(data["proposeCalldata"][10:])
                self.assertEqual(dynamic(body, 96), description.encode("utf-8"))
                self.assertEqual(data["description"], description)
                self.assertEqual(data["descriptionHash"], PROPOSAL.Cast().keccak(description.encode("utf-8")))

    def test_new_description_changes_proposal_id(self):
        first = PROPOSAL.generate(CSV, TOKEN, V2, "PIP-23 attempt 1")
        retry = PROPOSAL.generate(CSV, TOKEN, V2, "PIP-23 attempt 2")
        self.assertEqual(first["calldatas"], retry["calldatas"])
        self.assertNotEqual(first["proposalId"], retry["proposalId"])

    def test_duplicate_recipient_rejected(self):
        path = self.changed_csv(lambda rows: rows[1].update(address=rows[0]["address"]))
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            PROPOSAL.read_distribution(path)

    def test_zero_or_negative_amount_rejected(self):
        for amount in ("0", "-1", "1.5", "1e18"):
            path = self.changed_csv(lambda rows: rows[0].update(amount_wei=amount))
            with self.subTest(amount=amount), self.assertRaisesRegex(ValueError, "positive integer"):
                PROPOSAL.read_distribution(path)

    def test_display_amount_mismatch_rejected(self):
        path = self.changed_csv(lambda rows: rows[0].update(amount="1"))
        with self.assertRaisesRegex(ValueError, "disagrees"):
            PROPOSAL.read_distribution(path)

    def test_wrong_recipient_count_rejected(self):
        path = self.changed_csv(lambda rows: rows.pop())
        with self.assertRaisesRegex(ValueError, "138 recipients"):
            PROPOSAL.read_distribution(path)

    def test_hash_pin_rejects_changes_even_if_allocations_match(self):
        path = self.changed_csv(lambda rows: rows[0].update(note="modified"))
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            PROPOSAL.read_distribution(path)

    def test_invalid_or_reused_deployment_address_rejected(self):
        for token, v2 in (("0x" + "0" * 40, V2), (TOKEN, TOKEN), (PROPOSAL.GOVERNOR, V2), (TOKEN, PROPOSAL.TIMELOCK)):
            with self.subTest(token=token, v2=v2), self.assertRaises(ValueError):
                PROPOSAL.generate(CSV, token, v2, "PIP-23")

    def test_empty_description_rejected(self):
        with self.assertRaisesRegex(ValueError, "description"):
            PROPOSAL.generate(CSV, TOKEN, V2, " \n ")

    def test_cast_version_is_pinned(self):
        with patch.object(PROPOSAL.Cast, "call", return_value="cast Version: 1.0.0-nightly"):
            with self.assertRaisesRegex(ValueError, "Cast 1.7.1 is required"):
                PROPOSAL.Cast()

    def test_cli_outputs_only_json(self):
        result = subprocess.run([
            sys.executable, str(ROOT / "script/generate_pip23_proposal.py"), "--csv", str(CSV),
            "--new-pce", TOKEN, "--governor-v2", V2, "--description", "PIP-23 CLI",
        ], text=True, capture_output=True, check=True)
        self.assertEqual(result.stderr, "")
        self.assertEqual(json.loads(result.stdout)["description"], "PIP-23 CLI")


class PIP23RPCValidationTest(unittest.TestCase):
    def setUp(self):
        self.cast = PROPOSAL.Cast()
        self.impl = "0x3333333333333333333333333333333333333333"
        self.codes = {
            TOKEN: PROPOSAL.expected_runtime("out/ERC1967Proxy.sol/ERC1967Proxy.json", TOKEN, False),
            self.impl: PROPOSAL.expected_runtime("out/PCEMainnetToken.sol/PCEMainnetToken.json", self.impl, True),
            V2: PROPOSAL.expected_runtime("out-governor-mainnet/PCEGovernorV2.sol/PCEGovernorV2.json", V2, True),
        }
        self.slots = {PROPOSAL.ADMIN_SLOT: 0, PROPOSAL.IMPLEMENTATION_SLOT: int(self.impl, 16)}
        self.calls = {
            (TOKEN, self.cast.calldata("owner()")): int(PROPOSAL.TIMELOCK, 16),
            (TOKEN, self.cast.calldata("totalSupply()")): 0,
            (TOKEN, self.cast.calldata("distributionClosed()")): 0,
            (V2, self.cast.calldata("proxiableUUID()")): int(PROPOSAL.IMPLEMENTATION_SLOT, 16),
        }
        self.chain = "0x1"
        self.requests = []
        patcher = patch.object(PROPOSAL.RPC, "call", side_effect=self.rpc)
        patcher.start()
        self.addCleanup(patcher.stop)

    def rpc(self, method, params):
        self.requests.append((method, params))
        if method == "eth_chainId":
            return self.chain
        if method == "eth_blockNumber":
            return "0x1234"
        if method == "eth_getCode":
            return "0x" + self.codes.get(params[0], b"").hex()
        if method == "eth_getStorageAt":
            return f"0x{self.slots[params[1]]:064x}"
        if method == "eth_call":
            return f"0x{self.calls[(params[0]['to'], params[0]['data'])]:064x}"
        self.fail(f"Unexpected RPC method: {method}")

    def validate(self, token=TOKEN, v2=V2):
        return PROPOSAL.validate_deployments("https://example.invalid", token, v2, self.cast)

    def test_valid_deployments_are_checked_at_one_pinned_block(self):
        result = self.validate()
        self.assertEqual(result["blockNumber"], 0x1234)
        self.assertEqual(result["tokenImplementation"], self.impl)
        self.assertTrue(result["runtimeAndStateChecked"])
        for method, params in self.requests:
            if method not in ("eth_chainId", "eth_blockNumber"):
                self.assertEqual(params[-1], "0x1234")

    def test_explicit_block_and_json_validation_summary(self):
        result = PROPOSAL.generate(CSV, TOKEN, V2, "exact description", "https://example.invalid", 123)
        self.assertEqual(result["rpcValidation"]["blockNumber"], 123)
        self.assertFalse(any(m == "eth_blockNumber" for m, _ in self.requests))
        for method, params in self.requests:
            if method != "eth_chainId":
                self.assertEqual(params[-1], hex(123))

    def test_offline_mode_does_not_call_rpc(self):
        self.assertNotIn("rpcValidation", PROPOSAL.generate(CSV, TOKEN, V2, "offline"))
        self.assertEqual(self.requests, [])

    def test_swapped_addresses_rejected(self):
        with self.assertRaisesRegex(ValueError, "Runtime mismatch"):
            self.validate(V2, TOKEN)

    def test_token_implementation_instead_of_proxy_rejected(self):
        with self.assertRaisesRegex(ValueError, "Runtime mismatch"):
            self.validate(self.impl, V2)

    def test_known_old_governor_rejected_before_rpc(self):
        with self.assertRaisesRegex(ValueError, "old Governor"):
            self.validate(TOKEN, PROPOSAL.OLD_IMPLEMENTATION)
        self.assertEqual(self.requests, [])

    def test_wrong_governor_runtime_and_self_rejected(self):
        correct = self.codes[V2]
        for code in (b"", correct[:-1] + bytes([correct[-1] ^ 1]),
                     PROPOSAL.expected_runtime("out-governor-mainnet/PCEGovernorV2.sol/PCEGovernorV2.json", self.impl, True)):
            self.codes[V2] = code
            with self.subTest(code_size=len(code)), self.assertRaisesRegex(ValueError, "Runtime mismatch"):
                self.validate()

    def test_wrong_owner_supply_or_closed_rejected(self):
        for signature in ("owner()", "totalSupply()", "distributionClosed()"):
            key = TOKEN, self.cast.calldata(signature)
            before = self.calls[key]
            self.calls[key] = 1
            with self.subTest(signature=signature), self.assertRaises(ValueError):
                self.validate()
            self.calls[key] = before

    def test_invalid_admin_or_implementation_slot_rejected(self):
        for slot, value in ((PROPOSAL.ADMIN_SLOT, 1), (PROPOSAL.IMPLEMENTATION_SLOT, 0),
                            (PROPOSAL.IMPLEMENTATION_SLOT, 2**160), (PROPOSAL.IMPLEMENTATION_SLOT, int(V2, 16))):
            before = self.slots[slot]
            self.slots[slot] = value
            with self.subTest(slot=slot, value=value), self.assertRaises(ValueError):
                self.validate()
            self.slots[slot] = before

    def test_wrong_chain_rejected(self):
        self.chain = "0x89"
        with self.assertRaisesRegex(ValueError, "chainId 1"):
            self.validate()

    def test_proxy_as_governor_implementation_rejected(self):
        self.codes[V2] = self.codes[TOKEN]
        with self.assertRaisesRegex(ValueError, "Runtime mismatch"):
            self.validate()

    def test_rpc_failure_is_not_ignored(self):
        with patch.object(PROPOSAL.RPC, "call", side_effect=ValueError("RPC failed")):
            with self.assertRaisesRegex(ValueError, "RPC failed"):
                self.validate()

    def test_missing_artifact_has_build_instructions(self):
        with patch.object(PROPOSAL, "ROOT", ROOT / "cache/__nonexistent_artifact_root__"):
            with self.assertRaisesRegex(ValueError, "npm run build:pip23"):
                self.validate()


if __name__ == "__main__":
    unittest.main()
