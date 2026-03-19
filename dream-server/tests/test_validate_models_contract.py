#!/usr/bin/env python3
"""Contract tests for scripts/validate-models.py using unittest."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT_PATH = Path(__file__).resolve().parent.parent / "scripts" / "validate-models.py"
SPEC = importlib.util.spec_from_file_location("dream_validate_models", SCRIPT_PATH)
validate_models = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = validate_models
SPEC.loader.exec_module(validate_models)


class ValidateModelsContractTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmpdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tmpdir.name)
        self.fake_script = self.root / "scripts" / "validate-models.py"
        self.fake_script.parent.mkdir(parents=True, exist_ok=True)
        self.fake_script.write_text("# fixture script path\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.tmpdir.cleanup()

    def patch_script_root(self):
        return patch.object(validate_models, "__file__", str(self.fake_script))

    def make_file_with_size(self, relative_path: str, size_mb: int) -> Path:
        path = self.root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("wb") as handle:
            handle.truncate(size_mb * 1024 * 1024)
        return path

    def make_dir_with_size(self, relative_path: str, size_mb: int) -> Path:
        path = self.root / relative_path
        path.mkdir(parents=True, exist_ok=True)
        with (path / "blob.bin").open("wb") as handle:
            handle.truncate(size_mb * 1024 * 1024)
        return path

    def test_check_model_reports_missing_path(self) -> None:
        with self.patch_script_root():
            ok, message = validate_models.check_model("llm", validate_models.REQUIRED_MODELS["llm"])
        self.assertFalse(ok)
        self.assertIn("Not found", message)

    def test_check_model_rejects_file_that_is_too_small(self) -> None:
        self.make_file_with_size("data/kokoro/voices/af_heart.pt", 1)
        with self.patch_script_root():
            ok, message = validate_models.check_model("kokoro", validate_models.REQUIRED_MODELS["kokoro"])
        self.assertFalse(ok)
        self.assertIn("Too small", message)

    def test_check_model_accepts_large_enough_file(self) -> None:
        self.make_file_with_size("data/kokoro/voices/af_heart.pt", 200)
        with self.patch_script_root():
            ok, message = validate_models.check_model("kokoro", validate_models.REQUIRED_MODELS["kokoro"])
        self.assertTrue(ok)
        self.assertIn("OK:", message)

    def test_check_model_sums_directory_sizes(self) -> None:
        path = self.root / "data" / "embeddings" / "BAAI" / "bge-base-en-v1.5"
        path.mkdir(parents=True, exist_ok=True)
        (path / "part1.bin").write_bytes(b"x" * 120 * 1024 * 1024)
        (path / "part2.bin").write_bytes(b"x" * 120 * 1024 * 1024)

        with self.patch_script_root():
            ok, message = validate_models.check_model("embeddings", validate_models.REQUIRED_MODELS["embeddings"])
        self.assertTrue(ok)
        self.assertIn("OK:", message)

    def test_main_returns_one_and_lists_missing_models(self) -> None:
        stdout = io.StringIO()
        with self.patch_script_root(), contextlib.redirect_stdout(stdout):
            rc = validate_models.main()
        output = stdout.getvalue()

        self.assertEqual(rc, 1)
        self.assertIn("Dream Server Offline Mode - Model Validation", output)
        self.assertIn("MISSING MODELS", output)
        self.assertIn("download-models.sh", output)

    def test_main_returns_zero_when_all_models_are_present(self) -> None:
        self.make_dir_with_size("data/models", 3000)
        self.make_dir_with_size("data/whisper/faster-whisper-base", 100)
        self.make_file_with_size("data/kokoro/voices/af_heart.pt", 200)
        self.make_dir_with_size("data/embeddings/BAAI/bge-base-en-v1.5", 250)

        stdout = io.StringIO()
        with self.patch_script_root(), contextlib.redirect_stdout(stdout):
            rc = validate_models.main()
        output = stdout.getvalue()

        self.assertEqual(rc, 0)
        self.assertIn("All models present. Ready for offline mode!", output)
        self.assertIn("Primary LLM (GGUF model)", output)
        self.assertIn("Embedding model (BGE base)", output)

    def test_required_models_contract_contains_expected_services(self) -> None:
        self.assertEqual(set(validate_models.REQUIRED_MODELS), {"llm", "whisper", "kokoro", "embeddings"})
        self.assertEqual(validate_models.REQUIRED_MODELS["llm"]["path"], "data/models")
        self.assertEqual(validate_models.REQUIRED_MODELS["whisper"]["path"], "data/whisper/faster-whisper-base")

    def test_check_model_uses_repo_relative_root(self) -> None:
        with self.patch_script_root(), patch.object(validate_models.Path, "exists", autospec=True) as mock_exists:
            mock_exists.return_value = False
            ok, message = validate_models.check_model("llm", validate_models.REQUIRED_MODELS["llm"])
        self.assertFalse(ok)
        self.assertIn("Not found: data/models", message)

    def test_main_marks_individual_services_with_checkmarks_or_crosses(self) -> None:
        self.make_dir_with_size("data/models", 3000)
        stdout = io.StringIO()
        with self.patch_script_root(), contextlib.redirect_stdout(stdout):
            rc = validate_models.main()
        output = stdout.getvalue()

        self.assertEqual(rc, 1)
        self.assertIn("✓ Primary LLM (GGUF model)", output)
        self.assertIn("✗ Whisper STT model (base)", output)
        self.assertIn("✗ Embedding model (BGE base)", output)

    def test_descriptions_and_size_thresholds_are_stable(self) -> None:
        self.assertEqual(validate_models.REQUIRED_MODELS["llm"]["size_gb"], 4)
        self.assertEqual(validate_models.REQUIRED_MODELS["whisper"]["size_gb"], 0.15)
        self.assertEqual(validate_models.REQUIRED_MODELS["kokoro"]["description"], "Kokoro TTS voice (af_heart)")
        self.assertEqual(validate_models.REQUIRED_MODELS["embeddings"]["description"], "Embedding model (BGE base)")

    def test_check_model_rejects_half_size_boundary_below_threshold(self) -> None:
        # Expected threshold for whisper is 0.075 GB. About 50 MB should fail.
        self.make_dir_with_size("data/whisper/faster-whisper-base", 50)
        with self.patch_script_root():
            ok, message = validate_models.check_model("whisper", validate_models.REQUIRED_MODELS["whisper"])
        self.assertFalse(ok)
        self.assertIn("Too small", message)

    def test_check_model_accepts_half_size_boundary_above_threshold(self) -> None:
        # About 100 MB is above the 50% threshold for whisper.
        self.make_dir_with_size("data/whisper/faster-whisper-base", 100)
        with self.patch_script_root():
            ok, message = validate_models.check_model("whisper", validate_models.REQUIRED_MODELS["whisper"])
        self.assertTrue(ok)
        self.assertIn("OK:", message)

    def test_main_lists_specific_missing_service_ids(self) -> None:
        stdout = io.StringIO()
        with self.patch_script_root(), contextlib.redirect_stdout(stdout):
            rc = validate_models.main()
        output = stdout.getvalue()

        self.assertEqual(rc, 1)
        self.assertIn("llm", output)
        self.assertIn("whisper", output)
        self.assertIn("kokoro", output)
        self.assertIn("embeddings", output)

    def test_check_model_uses_fifty_percent_size_guard(self) -> None:
        expected = validate_models.REQUIRED_MODELS["embeddings"]["size_gb"] * 0.5
        self.assertAlmostEqual(expected, 0.2)

    def test_script_source_mentions_offline_mode_and_download_guidance(self) -> None:
        source = SCRIPT_PATH.read_text(encoding="utf-8")
        self.assertIn("offline mode", source.lower())
        self.assertIn("download-models.sh", source)
        self.assertIn("REQUIRED_MODELS", source)

    def test_main_prints_header_and_footer_rules(self) -> None:
        stdout = io.StringIO()
        with self.patch_script_root(), contextlib.redirect_stdout(stdout):
            validate_models.main()
        output = stdout.getvalue().splitlines()
        self.assertEqual(output[0], "=" * 60)
        self.assertEqual(output[2], "=" * 60)

    def test_required_model_paths_are_repo_relative(self) -> None:
        expected_paths = {
            "llm": "data/models",
            "whisper": "data/whisper/faster-whisper-base",
            "kokoro": "data/kokoro/voices/af_heart.pt",
            "embeddings": "data/embeddings/BAAI/bge-base-en-v1.5",
        }
        actual_paths = {name: cfg["path"] for name, cfg in validate_models.REQUIRED_MODELS.items()}
        self.assertEqual(actual_paths, expected_paths)

    def test_main_success_output_includes_all_descriptions(self) -> None:
        self.make_dir_with_size("data/models", 3000)
        self.make_dir_with_size("data/whisper/faster-whisper-base", 100)
        self.make_file_with_size("data/kokoro/voices/af_heart.pt", 200)
        self.make_dir_with_size("data/embeddings/BAAI/bge-base-en-v1.5", 250)

        stdout = io.StringIO()
        with self.patch_script_root(), contextlib.redirect_stdout(stdout):
            rc = validate_models.main()
        output = stdout.getvalue()

        self.assertEqual(rc, 0)
        for config in validate_models.REQUIRED_MODELS.values():
            self.assertIn(config["description"], output)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromModule(__import__(__name__))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
