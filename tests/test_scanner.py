from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from teslacam_cli.models import Camera
from teslacam_cli.scanner import normalize_camera, scan_clips


class ScannerTests(unittest.TestCase):
    def test_normalize_camera_variants(self):
        self.assertEqual(normalize_camera("front"), Camera.FRONT)
        self.assertEqual(normalize_camera("rear"), Camera.BACK)
        self.assertEqual(normalize_camera("left-repeater"), Camera.LEFT_REPEATER)
        self.assertEqual(normalize_camera("right_rear"), Camera.RIGHT_REPEATER)
        self.assertEqual(normalize_camera("left-pillar"), Camera.LEFT_PILLAR)
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


if __name__ == "__main__":
    unittest.main()
