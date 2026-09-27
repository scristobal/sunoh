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

    def test_saves_and_replaces_token_with_private_permissions(self):
        map_token.save_credentials("pk.test_payload.test-signature", self.destination)
        exported = self.destination.read_text()
        self.assertIn("SUNOH_MAPBOX_ACCESS_TOKEN = pk.test_payload.test-signature\n", exported)
        self.assertNotIn("SUNOH_MAP_ACCESS_CLIENT_SECRET", exported)
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o600)
        map_token.save_credentials("pk.replacement.signature", self.destination)
        self.assertNotIn("test-signature", self.destination.read_text())
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.root.glob(".maps-*")), [])

    def test_secret_and_malformed_tokens_preserve_existing_settings(self):
        self.destination.write_text("existing settings")
        for value in [None, 123, "", "sk.secret.signature", "pk.incomplete", "$(SETTING)",
                      "pk.payload.signature\nINJECTED = true", "pk.payload.signature // comment"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                map_token.save_credentials(value, self.destination)
            self.assertEqual(self.destination.read_text(), "existing settings")

    def test_token_rotation_preserves_style_and_removes_obsolete_credentials(self):
        style = "SUNOH_MAP_STYLE_URL = mapbox:/$()/styles/el-tobal/custom-style"
        self.destination.write_text(
            "SUNOH_MAPBOX_ACCESS_TOKEN = pk.old.signature\n"
            "SUNOH_MAP_ACCESS_CLIENT_ID = old-client\n"
            "SUNOH_MAP_ACCESS_CLIENT_SECRET = old-secret\n"
            f"{style}\n"
        )
        map_token.save_credentials("pk.replacement.signature", self.destination)
        exported = self.destination.read_text()
        self.assertIn(style + "\n", exported)
        self.assertIn("SUNOH_MAPBOX_ACCESS_TOKEN = pk.replacement.signature\n", exported)
        self.assertNotIn("old", exported)
        self.assertNotIn("SUNOH_MAP_ACCESS_CLIENT", exported)
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o600)

    def test_write_failure_preserves_existing_settings(self):
        self.destination.write_text("existing settings")
        with patch.object(map_token.os, "replace", side_effect=OSError("failed")):
            with self.assertRaises(OSError):
                map_token.save_credentials("pk.payload.signature", self.destination)
        self.assertEqual(self.destination.read_text(), "existing settings")
        self.assertEqual(list(self.root.glob(".maps-*")), [])

    def test_prompts_without_disclosing_token_or_writing_after_cancellation(self):
        output, error = io.StringIO(), io.StringIO()
        with patch.object(map_token.getpass, "getpass", return_value="pk.payload.signature"), \
             patch.object(map_token, "save_credentials") as save, \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            self.assertEqual(map_token.main(), 0)
            self.assertEqual(save.call_args.args[0], "pk.payload.signature")
        self.assertNotIn("pk.payload.signature", output.getvalue() + error.getvalue())
        with patch.object(map_token.getpass, "getpass", side_effect=EOFError), \
             patch.object(map_token, "save_credentials") as save, contextlib.redirect_stderr(error):
            self.assertEqual(map_token.main(), 1)
            save.assert_not_called()


if __name__ == "__main__":
    unittest.main()
