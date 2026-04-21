from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import Dict, List, Set


class Camera(str, Enum):
    FRONT = "front"
    BACK = "back"
    LEFT_REPEATER = "left_repeater"
    RIGHT_REPEATER = "right_repeater"
    LEFT = "left"
    RIGHT = "right"
    LEFT_PILLAR = "left_pillar"
    RIGHT_PILLAR = "right_pillar"

    @property
    def display_name(self) -> str:
        return {
            Camera.FRONT: "Front",
            Camera.BACK: "Back",
            Camera.LEFT_REPEATER: "Left repeater",
            Camera.RIGHT_REPEATER: "Right repeater",
            Camera.LEFT: "Left",
            Camera.RIGHT: "Right",
            Camera.LEFT_PILLAR: "Left pillar",
            Camera.RIGHT_PILLAR: "Right pillar",
        }[self]


HW3_CAMERA_ORDER = [
    Camera.FRONT,
    Camera.BACK,
    Camera.LEFT_REPEATER,
    Camera.RIGHT_REPEATER,
]

HW4_CAMERA_ORDER = [
    Camera.FRONT,
    Camera.BACK,
    Camera.LEFT,
    Camera.RIGHT,
    Camera.LEFT_PILLAR,
    Camera.RIGHT_PILLAR,
]

MIXED_CAMERA_ORDER = [
    *HW3_CAMERA_ORDER,
    *HW4_CAMERA_ORDER,
]


class LayoutKind(str, Enum):
    FOUR_UP = "4up"
    SIX_UP = "6up"


class DuplicatePolicy(str, Enum):
    MERGE_BY_TIME = "merge-by-time"
    KEEP_ALL = "keep-all"
    PREFER_NEWEST = "prefer-newest"

    @property
    def display_name(self) -> str:
        return {
            DuplicatePolicy.MERGE_BY_TIME: "Merge by time",
            DuplicatePolicy.KEEP_ALL: "Keep all",
            DuplicatePolicy.PREFER_NEWEST: "Prefer newest",
        }[self]


class OutputConflictPolicy(str, Enum):
    UNIQUE = "unique"
    OVERWRITE = "overwrite"
    ERROR = "error"

    @property
    def display_name(self) -> str:
        return {
            OutputConflictPolicy.UNIQUE: "Create a unique filename",
            OutputConflictPolicy.OVERWRITE: "Overwrite existing file",
            OutputConflictPolicy.ERROR: "Fail if the output exists",
        }[self]


@dataclass(frozen=True)
class ClipSet:
    timestamp: str
    start_time: datetime
    files: Dict[Camera, Path]


@dataclass(frozen=True)
class Dimensions:
    width: int
    height: int

    def to_size(self) -> str:
        return f"{self.width}x{self.height}"


@dataclass(frozen=True)
class SelectedSet:
    clip_set: ClipSet
    duration: float
    trim_start: float
    trim_end: float

    @property
    def rendered_duration(self) -> float:
        return max(0.0, self.trim_end - self.trim_start)


@dataclass(frozen=True)
class CellSpec:
    width: int
    height: int
    x: int
    y: int


@dataclass(frozen=True)
class LayoutSpec:
    kind: LayoutKind
    cameras: List[Camera]
    cell_by_camera: Dict[Camera, CellSpec]
    canvas_width: int
    canvas_height: int


@dataclass(frozen=True)
class EncoderPlan:
    mode: str
    args: List[str]
    output_extension: str
    label: str


@dataclass(frozen=True)
class ComposePlan:
    source_dir: Path
    output_file: Path
    ffmpeg: Path
    ffprobe: Path
    layout: LayoutSpec
    fps: float
    encoder: EncoderPlan
    selected_sets: List[SelectedSet]
    dimensions_by_camera: Dict[Camera, Dimensions]
    workdir: Path
    keep_workdir: bool
    loglevel: str


@dataclass(frozen=True)
class ScanResult:
    clip_sets: List[ClipSet]
    cameras: Set[Camera]
    duplicate_file_count: int
    duplicate_timestamp_count: int

    @property
    def has_conflicts(self) -> bool:
        return self.duplicate_file_count > 0 or self.duplicate_timestamp_count > 0
