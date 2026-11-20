"""Offline regression tests for the PIP-23 build/test entry points."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PIP23RunnerTest(unittest.TestCase):
    def setUp(self):
        cache = ROOT / "cache"
        cache.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="pip23-runner-", dir=cache)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "script").mkdir()
        shutil.copyfile(ROOT / "script/pip23.sh", self.root / "script/pip23.sh")
        (self.root / "script/verify_mainnet_governor.py").write_text("""
import json, os, sys
with open("calls.jsonl", "a") as f:
    f.write(json.dumps({"profile": "verify", "args": sys.argv[1:]}) + "\\n")
sys.exit(int(os.environ.get("FAKE_VERIFY_EXIT", "0")))
""")
        self.forge = self.root / "fake forge"
        self.forge.write_text(f"#!{sys.executable}\n" + '''
import json, os, pathlib, sys
args = sys.argv[1:]
if args == ["--version"]:
    print("forge Version: " + os.environ.get("FAKE_FORGE_VERSION", "1.7.1"))
    print("Commit SHA: test")
    sys.exit(0)
with open("calls.jsonl", "a") as f:
    f.write(json.dumps({"profile": os.environ.get("FOUNDRY_PROFILE"), "args": args,
                       "fork_block": os.environ.get("FORK_BLOCK"),
                       "old_build_info": pathlib.Path("out/build-info/stale.json").exists()}) + "\\n")
if args[0] == "build" and os.environ.get("FOUNDRY_PROFILE") == os.environ.get("FAKE_FORGE_FAIL_PROFILE"):
    sys.exit(17)
''')
        self.forge.chmod(0o755)
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.startswith(("FOUNDRY_", "DAPP_")) or key in ("FORK_RPC_URL", "FORK_BLOCK", "FORGE"):
                del self.env[key]
        self.env["FORGE"] = str(self.forge)

    def run_script(self, mode, *args, **env):
        return subprocess.run(
            ["bash", "script/pip23.sh", mode, *args], cwd=self.root,
            env={**self.env, **env}, text=True, capture_output=True, check=False,
        )

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_rehearsal_rejects_missing_rpc_before_build(self):
        result = self.run_script("test-pip23")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FORK_RPC_URL is required", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_rehearsal_rejects_whitespace_rpc(self):
        result = self.run_script("test-pip23", FORK_RPC_URL=" \t ")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FORK_RPC_URL is required", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_wrong_forge_version_fails_before_build(self):
        for version in ("1.0.0-nightly", "1.7.10", "1.7.1-nightly", "1.8.0"):
            with self.subTest(version=version):
                result = self.run_script("build", FAKE_FORGE_VERSION=version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Forge 1.7.1 is required", result.stderr)
                self.assertEqual(self.calls(), [])

    def test_missing_executable_has_actionable_error(self):
        result = self.run_script("build", FORGE=str(self.root / "does-not-exist"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Set FORGE=/absolute/path/to/forge-1.7.1", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_normal_test_force_builds_both_profiles_without_rpc(self):
        result = self.run_script("test", "--code-size-limit", "1000000", FOUNDRY_PROFILE="wrong")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual([(c["profile"], c["args"]) for c in calls], [
            ("governor_mainnet", ["build", "--force"]),
            ("default", ["build", "--force"]),
            ("default", ["test", "--code-size-limit", "1000000"]),
        ])

    def test_build_clears_old_default_build_info(self):
        info = self.root / "out/build-info"
        info.mkdir(parents=True)
        (info / "stale.json").write_text("stale")
        result = self.run_script("build")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.calls()[0]["old_build_info"])
        self.assertFalse(self.calls()[1]["old_build_info"])

    def test_rehearsal_builds_then_validates_then_runs_isolated_fork(self):
        result = self.run_script("test-pip23", FORK_RPC_URL="https://example.invalid", FORK_BLOCK="123")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual(len(calls), 6)
        self.assertEqual(calls[0]["args"], ["build", "--force"])
        self.assertEqual(calls[1]["args"], ["build", "--force"])
        self.assertEqual(calls[2], {"profile": "verify", "args": ["--rpc-url", "https://example.invalid"]})
        self.assertEqual(calls[3]["profile"], "governor_mainnet")
        self.assertEqual(calls[3]["args"], ["test", "-vv"])
        self.assertEqual(calls[4]["profile"], "default")
        self.assertEqual(calls[5]["args"], ["test", "--isolate", "--match-path", "test/PIP23Fork.t.sol", "-vv"])
        self.assertEqual(calls[5]["fork_block"], "123")

    def test_runtime_mismatch_stops_before_tests(self):
        result = self.run_script("test-pip23", FORK_RPC_URL="https://example.invalid", FAKE_VERIFY_EXIT="19")
        self.assertEqual(result.returncode, 19)
        self.assertEqual(len(self.calls()), 3)
        self.assertEqual(self.calls()[-1]["profile"], "verify")

    def test_build_override_environment_is_rejected(self):
        for name in ("FOUNDRY_OPTIMIZER_RUNS", "FOUNDRY_CONFIG", "FOUNDRY_OUT", "FOUNDRY_SOLC",
                     "FOUNDRY_UNKNOWN_FUTURE_SETTING", "DAPP_SOLC_VERSION", "DAPP_BUILD_OPTIMIZE_RUNS"):
            for value in ("999", ""):
                with self.subTest(name=name, value=value):
                    result = self.run_script("build", **{name: value})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(name, result.stderr)
                    self.assertEqual(self.calls(), [])

    def test_build_failure_stops_before_using_stale_artifacts(self):
        result = self.run_script("test", FAKE_FORGE_FAIL_PROFILE="default")
        self.assertEqual(result.returncode, 17)
        self.assertEqual(len(self.calls()), 2)
        self.assertTrue(all(call["args"][0] == "build" for call in self.calls()))

    def test_governor_build_uses_pinned_runner(self):
        result = self.run_script("build-governor")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.calls()[0]["profile"], "governor_mainnet")
        self.assertEqual(self.calls()[0]["args"], ["build", "--force"])

    def test_package_entry_points_and_clean(self):
        scripts = json.loads((ROOT / "package.json").read_text())["scripts"]
        self.assertEqual(scripts["test"], "bash script/pip23.sh test")
        self.assertEqual(scripts["test:pip23"], "bash script/pip23.sh test-pip23")
        self.assertEqual(scripts["build:pip23"], "bash script/pip23.sh build")
        outputs = ("cache", "out", "out-governor-mainnet", "cache-governor-mainnet")
        for name in outputs:
            (self.root / name).mkdir()
            (self.root / name / "dummy").write_text("generated")
        subprocess.run(["bash", "-c", scripts["clean"]], cwd=self.root, check=True)
        self.assertTrue(all(not (self.root / name).exists() for name in outputs))


if __name__ == "__main__":
    unittest.main()
