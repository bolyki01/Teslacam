from __future__ import annotations

import re
from datetime import datetime
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set

from .models import Camera, ClipSet

_TIMESTAMP_FORMAT = "%Y-%m-%d_%H-%M-%S"
_FILENAME_RE = re.compile(
    r"^(?P<timestamp>\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})-(?P<camera>[A-Za-z0-9_-]+)\.(mp4|mov)$",
    re.IGNORECASE,
)


def parse_clip_timestamp(value: str) -> datetime:
    return datetime.strptime(value, _TIMESTAMP_FORMAT)


def format_clip_timestamp(value: datetime) -> str:
    return value.strftime(_TIMESTAMP_FORMAT)


def normalize_camera(raw: str) -> Optional[Camera]:
    token = raw.lower().replace("-", "_")
    token = re.sub(r"_+", "_", token)
    token = re.sub(r"_?\d+$", "", token)

    if token in {"front", "fwd", "forward"}:
        return Camera.FRONT
    if token in {"back", "rear", "rear_camera"}:
        return Camera.BACK
    if "left" in token and "pillar" in token:
        return Camera.LEFT_PILLAR
    if "right" in token and "pillar" in token:
        return Camera.RIGHT_PILLAR
    if ("left" in token and "repeat" in token) or token in {"left", "left_rear"}:
        return Camera.LEFT_REPEATER
    if ("right" in token and "repeat" in token) or token in {"right", "right_rear"}:
        return Camera.RIGHT_REPEATER

    try:
        return Camera(token)
    except ValueError:
        return None


def scan_clips(root: Path) -> List[ClipSet]:
    if not root.exists() or not root.is_dir():
        raise FileNotFoundError(f"Source directory does not exist: {root}")

    grouped: Dict[str, Dict[Camera, Path]] = {}
    dates: Dict[str, datetime] = {}

    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if path.suffix.lower() not in {".mp4", ".mov"}:
            continue
        match = _FILENAME_RE.match(path.name)
        if not match:
            continue
        timestamp = match.group("timestamp")
        camera = normalize_camera(match.group("camera"))
        if camera is None:
            continue

        if timestamp not in grouped:
            grouped[timestamp] = {}
            dates[timestamp] = parse_clip_timestamp(timestamp)

        existing = grouped[timestamp].get(camera)
        if existing is None or str(path) < str(existing):
            grouped[timestamp][camera] = path

    clip_sets = [
        ClipSet(timestamp=timestamp, start_time=dates[timestamp], files=grouped[timestamp])
        for timestamp in grouped
    ]
    clip_sets.sort(key=lambda item: (item.start_time, item.timestamp))
    if not clip_sets:
        raise RuntimeError(f"No TeslaCam clips found under: {root}")
    return clip_sets


def cameras_in_sets(clip_sets: Iterable[ClipSet]) -> Set[Camera]:
    cameras: Set[Camera] = set()
    for clip_set in clip_sets:
        cameras.update(clip_set.files.keys())
    return cameras
