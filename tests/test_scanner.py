from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from teslacam_cli.models import Camera, DuplicatePolicy
from teslacam_cli.scanner import normalize_camera, scan_clips, scan_source


class ScannerTests(unittest.TestCase):
    def test_normalize_camera_variants(self):
        self.assertEqual(normalize_camera("front"), Camera.FRONT)
        self.assertEqual(normalize_camera("rear"), Camera.BACK)
        self.assertEqual(normalize_camera("left-repeater"), Camera.LEFT_REPEATER)
        self.assertEqual(normalize_camera("left_rear"), Camera.LEFT_REPEATER)
        self.assertEqual(normalize_camera("left"), Camera.LEFT)
        self.assertEqual(normalize_camera("right_repeater"), Camera.RIGHT_REPEATER)
        self.assertEqual(normalize_camera("right_rear"), Camera.RIGHT_REPEATER)
        self.assertEqual(normalize_camera("right"), Camera.RIGHT)
        self.assertEqual(normalize_camera("left-pillar"), Camera.LEFT_PILLAR)
        self.assertEqual(normalize_camera("right_pillar"), Camera.RIGHT_PILLAR)
        self.assertIsNone(normalize_camera("unknown_camera"))

    def test_scan_groups_by_timestamp(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            for name in [
                "2026-01-01_00-00-00-front.mp4",
                "2026-01-01_00-00-00-rear.mp4",
                "2026-01-01_00-00-00-left_repeater.mov",
                "2026-01-01_00-00-00-right_repeater.mp4",
                "2026-01-01_00-01-00-front.mp4",
            ]:
                (root / name).write_bytes(b"x")
            sets = scan_clips(root)
            self.assertEqual(len(sets), 2)
            self.assertIn(Camera.FRONT, sets[0].files)
            self.assertIn(Camera.BACK, sets[0].files)
            self.assertIn(Camera.LEFT_REPEATER, sets[0].files)
            self.assertIn(Camera.RIGHT_REPEATER, sets[0].files)

    def test_scan_groups_hw4_names(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            for name in [
                "2026-01-01_00-00-00-front.mp4",
                "2026-01-01_00-00-00-rear.mp4",
                "2026-01-01_00-00-00-left.mp4",
                "2026-01-01_00-00-00-right.mp4",
                "2026-01-01_00-00-00-left_pillar.mp4",
                "2026-01-01_00-00-00-right_pillar.mp4",
            ]:
                (root / name).write_bytes(b"x")
            sets = scan_clips(root)
            self.assertEqual(len(sets), 1)
            self.assertIn(Camera.LEFT, sets[0].files)
            self.assertIn(Camera.RIGHT, sets[0].files)
            self.assertIn(Camera.LEFT_PILLAR, sets[0].files)
            self.assertIn(Camera.RIGHT_PILLAR, sets[0].files)

    def test_duplicate_policy_prefer_newest_uses_latest_file(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            older_dir = root / "older"
            newer_dir = root / "newer"
            older_dir.mkdir()
            newer_dir.mkdir()
            older = older_dir / "2026-01-01_00-00-00-front.mp4"
            newer = newer_dir / "2026-01-01_00-00-00-front.mp4"
            (root / "2026-01-01_00-00-00-rear.mp4").write_bytes(b"rear")
            older.write_bytes(b"older")
            newer.write_bytes(b"newer")
            import os

            older_mtime = 1_700_000_000
            newer_mtime = 1_700_000_100
            os.utime(older, (older_mtime, older_mtime))
            os.utime(newer, (newer_mtime, newer_mtime))

            result = scan_source(root, duplicate_policy=DuplicatePolicy.PREFER_NEWEST)

        self.assertEqual(result.duplicate_file_count, 1)
        self.assertEqual(result.duplicate_timestamp_count, 1)
        self.assertEqual(len(result.clip_sets), 1)
        self.assertEqual(result.clip_sets[0].files[Camera.FRONT], newer)

    def test_duplicate_policy_keep_all_preserves_duplicate_entries(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            folder_a = root / "folder_a"
            folder_b = root / "folder_b"
            folder_a.mkdir()
            folder_b.mkdir()
            front_a = folder_a / "2026-01-01_00-00-00-front.mp4"
            front_b = folder_b / "2026-01-01_00-00-00-front.mp4"
            rear = root / "2026-01-01_00-00-00-rear.mp4"
            front_a.write_bytes(b"a")
            front_b.write_bytes(b"b")
            rear.write_bytes(b"rear")

            result = scan_source(root, duplicate_policy=DuplicatePolicy.KEEP_ALL)

        self.assertEqual(result.duplicate_file_count, 1)
        self.assertEqual(result.duplicate_timestamp_count, 1)
        self.assertEqual(len(result.clip_sets), 2)
        self.assertEqual(result.clip_sets[0].files[Camera.BACK], rear)
        self.assertTrue(any(clip_set.files.get(Camera.FRONT) == front_a for clip_set in result.clip_sets))
        self.assertTrue(any(clip_set.files.get(Camera.FRONT) == front_b for clip_set in result.clip_sets))


if __name__ == "__main__":
    unittest.main()
