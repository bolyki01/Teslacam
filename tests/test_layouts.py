import unittest

from teslacam_cli.layouts import build_layout, fill_missing_dimensions
from teslacam_cli.models import Camera, Dimensions, LayoutKind


class LayoutTests(unittest.TestCase):
    def test_four_up_canvas_uses_per_column_and_row_max(self):
        layout = build_layout(
            LayoutKind.FOUR_UP,
            {
                Camera.FRONT: Dimensions(1920, 1080),
                Camera.BACK: Dimensions(1280, 720),
                Camera.LEFT_REPEATER: Dimensions(1280, 960),
                Camera.RIGHT_REPEATER: Dimensions(1280, 960),
            },
        )
        self.assertEqual(layout.canvas_width, 3200)
        self.assertEqual(layout.canvas_height, 2040)
        self.assertEqual(layout.cell_by_camera[Camera.FRONT].width, 1920)
        self.assertEqual(layout.cell_by_camera[Camera.BACK].width, 1280)
        self.assertEqual(layout.cell_by_camera[Camera.LEFT_REPEATER].y, 1080)

    def test_fill_missing_dimensions_uses_max_known(self):
        complete = fill_missing_dimensions(
            LayoutKind.SIX_UP,
            {
                Camera.FRONT: Dimensions(1920, 1080),
                Camera.BACK: Dimensions(1920, 1080),
            },
        )
        self.assertEqual(complete[Camera.LEFT_PILLAR].width, 1920)
        self.assertEqual(complete[Camera.RIGHT_REPEATER].height, 1080)


if __name__ == "__main__":
    unittest.main()
