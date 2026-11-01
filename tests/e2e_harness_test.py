"""Exercise release-run failure boundaries without using the host Mac."""

from contextlib import ExitStack, redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "e2e_macos", Path(__file__).resolve().parents[1] / "scripts/e2e_macos.py")
E2E = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(E2E)


class DependencyTests(unittest.TestCase):
    def run_candidate(self, failed=None, keep_going=True, skip_build=False, download_fixture=None):
        with tempfile.TemporaryDirectory() as tmp, ExitStack() as stack:
            root = Path(tmp)
            run = object.__new__(E2E.Run)
            run.id, run.dir = "fixture", root
            run.keep_going, run.steps, run.failed = keep_going, [], False
            run.dmg = None
            run.token = "fixture"
            calls = []
            real_download = E2E.download
            names = ("preflight", "build", "download", "install", "launch", "uninstall",
                     "history", "installer", "analyze", "smoke")
            for name in names:
                def action(_run, name=name):
                    calls.append(name)
                    if name == "download" and download_fixture:
                        return real_download(_run)
                    if name == failed:
                        raise E2E.StepFailed("injected failure: " + name)
                stack.enter_context(patch.object(E2E, name, side_effect=action))
            stack.enter_context(patch.object(E2E, "Run", return_value=run))
            stack.enter_context(patch.object(E2E, "APP_PATH", root / "absent.app"))
            stack.enter_context(patch.object(E2E, "fixture_traces", return_value=[]))
            stack.enter_context(patch.object(E2E.platform, "system", return_value="Darwin"))
            stack.enter_context(patch.object(E2E.subprocess, "run", side_effect=AssertionError("real process")))
            stack.enter_context(patch.object(E2E.subprocess, "Popen", side_effect=AssertionError("real terminal")))
            stack.enter_context(patch.object(E2E.urllib.request, "urlopen", side_effect=AssertionError("real network")))
            if download_fixture:
                (root / "Downloads").mkdir()
                stack.enter_context(patch.object(E2E, "HOME", root))
                asset = {"name": "fixture.dmg", "browser_download_url": "https://fixture.invalid/fixture.dmg",
                         "digest": "sha256:" + "0" * 64}
                response = io.BytesIO(json.dumps({"assets": [asset]}).encode())
                payload = OSError("download interrupted") if download_fixture == "network" else io.BytesIO(b"unverified image")
                stack.enter_context(patch.object(E2E.urllib.request, "urlopen", side_effect=[response, payload]))
            argv = ["e2e"] + (["--keep-going"] if keep_going else []) + (["--skip-build"] if skip_build else [])
            stack.enter_context(patch("sys.argv", argv))
            with redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as exit_result:
                E2E.main()
            report = json.loads((root / "report.json").read_text())
            self.assertEqual(exit_result.exception.code, 1 if failed else 0)
            return calls, report["steps"]

    def test_failed_prerequisites_block_dependent_actions_with_keep_going(self):
        expected = {
            "preflight": ["preflight"],
            "build": ["preflight", "build"],
            "download": ["preflight", "build", "download", "smoke"],
            "install": ["preflight", "build", "download", "install", "installer", "smoke"],
            "launch": ["preflight", "build", "download", "install", "launch", "installer", "smoke"],
            "uninstall": ["preflight", "build", "download", "install", "launch", "uninstall", "installer", "smoke"],
        }
        for failed, wanted in expected.items():
            with self.subTest(failed=failed):
                calls, steps = self.run_candidate(failed)
                self.assertEqual(calls, wanted)
                self.assertIn("skipped", [step["status"] for step in steps])

    def test_read_only_failure_keeps_independent_analyze_and_smoke(self):
        calls, _ = self.run_candidate("installer")
        self.assertEqual(calls[-3:], ["installer", "analyze", "smoke"])

    def test_default_stops_after_first_failure(self):
        calls, _ = self.run_candidate("download", keep_going=False)
        self.assertEqual(calls, ["preflight", "build", "download"])

    def test_failed_transfer_and_checksum_block_installation(self):
        for failure in ("network", "checksum"):
            with self.subTest(failure=failure):
                calls, steps = self.run_candidate("download", download_fixture=failure)
                self.assertEqual(calls, ["preflight", "build", "download", "smoke"])
                self.assertIn("download interrupted" if failure == "network" else "sha256 mismatch",
                              next(step["detail"] for step in steps if step["status"] == "failed"))

    def test_success_and_explicit_skip_build_keep_the_full_flow(self):
        for skip in (False, True):
            with self.subTest(skip_build=skip):
                calls, steps = self.run_candidate(skip_build=skip)
                self.assertEqual(calls, ["preflight"] + ([] if skip else ["build"]) + [
                    "download", "install", "launch", "uninstall", "history", "installer", "analyze", "smoke"])
                self.assertTrue(all(step["status"] == "passed" for step in steps))


class DownloadTests(unittest.TestCase):
    def test_rate_limited_release_lookup_falls_back_to_signed_in_gh(self):
        image = b"verified image"
        asset = {"name": "fixture.dmg", "browser_download_url": "https://fixture.invalid/fixture.dmg",
                 "digest": "sha256:" + hashlib.sha256(image).hexdigest()}
        limited = E2E.urllib.error.HTTPError("https://api.github.com", 403, "rate limit exceeded", {}, None)
        gh = SimpleNamespace(returncode=0, stdout=json.dumps({"tag_name": "v1", "assets": [asset]}), stderr="")
        with tempfile.TemporaryDirectory() as tmp, ExitStack() as stack:
            root = Path(tmp)
            (root / "Downloads").mkdir()
            stack.enter_context(patch.object(E2E, "HOME", root))
            stack.enter_context(patch.object(E2E.urllib.request, "urlopen", side_effect=[limited, io.BytesIO(image)]))
            stack.enter_context(patch.object(E2E.shutil, "which", return_value="/usr/local/bin/gh"))
            capture = stack.enter_context(patch.object(E2E, "capture", return_value=gh))
            result = E2E.download(SimpleNamespace(token="t"))
        self.assertEqual(capture.call_args.args[0][:2], ["gh", "api"])
        self.assertIn("fixture.dmg", result)


if __name__ == "__main__":
    unittest.main()
