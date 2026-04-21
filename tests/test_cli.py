from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from teslacam_cli.cli import apply_output_conflict_policy, resolve_output_path, unique_output_path
from teslacam_cli.models import OutputConflictPolicy


class CliPathTests(unittest.TestCase):
    def test_unique_output_path_adds_incrementing_suffix(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            original = root / "out.mp4"
            second = root / "out-2.mp4"
            original.write_bytes(b"x")
            second.write_bytes(b"x")

            resolved = unique_output_path(original)

        self.assertEqual(resolved.name, "out-3.mp4")

    def test_apply_output_conflict_policy_errors_when_requested(self):
        with TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "existing.mp4"
            path.write_bytes(b"x")

            with self.assertRaises(RuntimeError):
                apply_output_conflict_policy(path, OutputConflictPolicy.ERROR)

    def test_resolve_output_path_uses_directory_argument_as_output_folder(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "source"
            destination = root / "exports"
            source.mkdir()
            destination.mkdir()
            start = datetime(2026, 1, 1, 0, 0, 0)
            end = datetime(2026, 1, 1, 0, 1, 0)

            resolved = resolve_output_path(
                source,
                str(destination),
                mode="lossless",
                start_time=start,
                end_time=end,
                output_conflict=OutputConflictPolicy.UNIQUE,
            )

        self.assertEqual(resolved.parent, destination.resolve())
        self.assertTrue(resolved.name.startswith("teslacam_lossless_"))
        self.assertEqual(resolved.suffix, ".mp4")


if __name__ == "__main__":
    unittest.main()
