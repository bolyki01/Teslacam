from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import Dict, List


class Camera(str, Enum):
    FRONT = "front"
    BACK = "back"
    LEFT_REPEATER = "left_repeater"
    RIGHT_REPEATER = "right_repeater"
    LEFT_PILLAR = "left_pillar"
    RIGHT_PILLAR = "right_pillar"

    @property
    def display_name(self) -> str:
        return {
            Camera.FRONT: "Front",
            Camera.BACK: "Back",
            Camera.LEFT_REPEATER: "Left repeater",
            Camera.RIGHT_REPEATER: "Right repeater",
            Camera.LEFT_PILLAR: "Left pillar",
            Camera.RIGHT_PILLAR: "Right pillar",
        }[self]


class LayoutKind(str, Enum):
    FOUR_UP = "4up"
    SIX_UP = "6up"


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
