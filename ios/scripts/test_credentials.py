import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("map_token", Path(__file__).with_name("credentials.py"))
map_token = importlib.util.module_from_spec(spec)
spec.loader.exec_module(map_token)


class CredentialTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.destination = self.root / "Maps.local.xcconfig"

    def test_saves_and_replaces_credentials_with_private_permissions(self):
        map_token.save_credentials("test.access", "cfast_test-secret", self.destination)
        exported = self.destination.read_text()
        self.assertIn("SUNOH_MAP_ACCESS_CLIENT_ID = test.access\n", exported)
        self.assertIn("SUNOH_MAP_ACCESS_CLIENT_SECRET = cfast_test-secret\n", exported)
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o600)
        map_token.save_credentials("replacement.access", "cfast_replacement", self.destination)
        self.assertNotIn("test-secret", self.destination.read_text())
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.root.glob(".maps-*")), [])

    def test_invalid_pair_preserves_existing_settings(self):
        self.destination.write_text("existing settings")
        for value in [None, 123, "", "$(SETTING)", "secret\nINJECTED = true", "secret // comment"]:
            for pair in [(value, "cfast_secret"), ("test.access", value)]:
                with self.subTest(pair=pair), self.assertRaises(ValueError):
                    map_token.save_credentials(*pair, self.destination)
                self.assertEqual(self.destination.read_text(), "existing settings")

    def test_write_failure_preserves_existing_settings(self):
        self.destination.write_text("existing settings")
        with patch.object(map_token.os, "replace", side_effect=OSError("failed")):
            with self.assertRaises(OSError):
                map_token.save_credentials("test.access", "cfast_secret", self.destination)
        self.assertEqual(self.destination.read_text(), "existing settings")
        self.assertEqual(list(self.root.glob(".maps-*")), [])

    def test_prompts_without_disclosing_secret_or_writing_after_cancellation(self):
        output, error = io.StringIO(), io.StringIO()
        with patch("builtins.input", return_value="test.access"), \
             patch.object(map_token.getpass, "getpass", return_value="cfast_test-secret"), \
             patch.object(map_token, "save_credentials") as save, \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            self.assertEqual(map_token.main(), 0)
            self.assertEqual(save.call_args.args[:2], ("test.access", "cfast_test-secret"))
        self.assertNotIn("cfast_test-secret", output.getvalue() + error.getvalue())
        with patch("builtins.input", return_value="test.access"), \
             patch.object(map_token.getpass, "getpass", side_effect=EOFError), \
             patch.object(map_token, "save_credentials") as save, contextlib.redirect_stderr(error):
            self.assertEqual(map_token.main(), 1)
            save.assert_not_called()


if __name__ == "__main__":
    unittest.main()
