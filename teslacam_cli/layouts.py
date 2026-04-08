from __future__ import annotations

from typing import Dict, Iterable, List, Tuple

from .models import Camera, CellSpec, Dimensions, LayoutKind, LayoutSpec

PROFILE_LABELS = {
    "auto": "Auto-detect from clips",
    "legacy4": "Tesla legacy 4-camera layout",
    "sixcam": "Tesla 6-camera layout (pillar clips present)",
}

_LAYOUT_GRIDS: Dict[LayoutKind, Dict[Camera, Tuple[int, int]]] = {
    LayoutKind.FOUR_UP: {
        Camera.FRONT: (0, 0),
        Camera.BACK: (0, 1),
        Camera.LEFT_REPEATER: (1, 0),
        Camera.RIGHT_REPEATER: (1, 1),
    },
    LayoutKind.SIX_UP: {
        Camera.FRONT: (0, 0),
        Camera.BACK: (0, 1),
        Camera.LEFT_REPEATER: (0, 2),
        Camera.RIGHT_REPEATER: (1, 0),
        Camera.LEFT_PILLAR: (1, 1),
        Camera.RIGHT_PILLAR: (1, 2),
    },
}

_DEFAULT_DIMENSIONS = Dimensions(width=1280, height=960)



def detect_layout_kind(profile: str, available_cameras: Iterable[Camera]) -> LayoutKind:
    camera_set = set(available_cameras)
    if profile == "legacy4":
        return LayoutKind.FOUR_UP
    if profile == "sixcam":
        return LayoutKind.SIX_UP
    if Camera.LEFT_PILLAR in camera_set or Camera.RIGHT_PILLAR in camera_set:
        return LayoutKind.SIX_UP
    return LayoutKind.FOUR_UP



def expected_cameras(layout: LayoutKind) -> List[Camera]:
    grid = _LAYOUT_GRIDS[layout]
    return [camera for camera, _ in sorted(grid.items(), key=lambda item: item[1])]



def fill_missing_dimensions(layout: LayoutKind, probed: Dict[Camera, Dimensions]) -> Dict[Camera, Dimensions]:
    cameras = expected_cameras(layout)
    if probed:
        fallback = Dimensions(
            width=max(value.width for value in probed.values()),
            height=max(value.height for value in probed.values()),
        )
    else:
        fallback = _DEFAULT_DIMENSIONS
    complete: Dict[Camera, Dimensions] = {}
    for camera in cameras:
        complete[camera] = probed.get(camera, fallback)
    return complete



def build_layout(layout: LayoutKind, dimensions_by_camera: Dict[Camera, Dimensions]) -> LayoutSpec:
    grid = _LAYOUT_GRIDS[layout]
    row_count = max(position[0] for position in grid.values()) + 1
    col_count = max(position[1] for position in grid.values()) + 1

    row_heights = [0 for _ in range(row_count)]
    col_widths = [0 for _ in range(col_count)]

    for camera, (row, col) in grid.items():
        dims = dimensions_by_camera[camera]
        row_heights[row] = max(row_heights[row], dims.height)
        col_widths[col] = max(col_widths[col], dims.width)

    x_offsets = [0]
    for width in col_widths[:-1]:
        x_offsets.append(x_offsets[-1] + width)
    y_offsets = [0]
    for height in row_heights[:-1]:
        y_offsets.append(y_offsets[-1] + height)

    cell_by_camera: Dict[Camera, CellSpec] = {}
    for camera, (row, col) in grid.items():
        cell_by_camera[camera] = CellSpec(
            width=col_widths[col],
            height=row_heights[row],
            x=x_offsets[col],
            y=y_offsets[row],
        )

    return LayoutSpec(
        kind=layout,
        cameras=expected_cameras(layout),
        cell_by_camera=cell_by_camera,
        canvas_width=sum(col_widths),
        canvas_height=sum(row_heights),
    )
