from __future__ import annotations

import os
import re
from datetime import datetime
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set

from .models import Camera, ClipSet, DuplicatePolicy, ScanResult

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
    if "left" in token and "repeat" in token:
        return Camera.LEFT_REPEATER
    if "right" in token and "repeat" in token:
        return Camera.RIGHT_REPEATER
    if token == "left_rear":
        return Camera.LEFT_REPEATER
    if token == "right_rear":
        return Camera.RIGHT_REPEATER
    if token == "left":
        return Camera.LEFT
    if token == "right":
        return Camera.RIGHT

    try:
        return Camera(token)
    except ValueError:
        return None


def scan_source(
    root: Path,
    duplicate_policy: DuplicatePolicy = DuplicatePolicy.MERGE_BY_TIME,
) -> ScanResult:
    if not root.exists() or not root.is_dir():
        raise FileNotFoundError(f"Source directory does not exist: {root}")

    grouped: Dict[str, Dict[Camera, Path]] = {}
    dates: Dict[str, datetime] = {}
    keep_all_sets: List[ClipSet] = []
    keep_all_primary_index_by_timestamp: Dict[str, int] = {}
    cameras_found: Set[Camera] = set()
    duplicate_file_count = 0
    duplicate_timestamp_count = 0
    seen_duplicate_timestamps: Set[str] = set()

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
            dates[timestamp] = parse_clip_timestamp(timestamp)

        start_time = dates[timestamp]

        if duplicate_policy == DuplicatePolicy.KEEP_ALL:
            primary_index = keep_all_primary_index_by_timestamp.get(timestamp)
            if primary_index is None:
                keep_all_primary_index_by_timestamp[timestamp] = len(keep_all_sets)
                keep_all_sets.append(ClipSet(timestamp=timestamp, start_time=start_time, files={camera: path}))
            else:
                primary = keep_all_sets[primary_index]
                if camera not in primary.files:
                    files = dict(primary.files)
                    files[camera] = path
                    keep_all_sets[primary_index] = ClipSet(
                        timestamp=primary.timestamp,
                        start_time=primary.start_time,
                        files=files,
                    )
                else:
                    duplicate_file_count += 1
                    if timestamp not in seen_duplicate_timestamps:
                        seen_duplicate_timestamps.add(timestamp)
                        duplicate_timestamp_count += 1
                    keep_all_sets.append(ClipSet(timestamp=timestamp, start_time=start_time, files={camera: path}))
            cameras_found.add(camera)
            continue

        if timestamp not in grouped:
            grouped[timestamp] = {}

        existing = grouped[timestamp].get(camera)
        if existing is None:
            grouped[timestamp][camera] = path
        else:
            duplicate_file_count += 1
            if timestamp not in seen_duplicate_timestamps:
                seen_duplicate_timestamps.add(timestamp)
                duplicate_timestamp_count += 1
            grouped[timestamp][camera] = _resolve_duplicate_path(existing, path, duplicate_policy)
        cameras_found.add(camera)

    if duplicate_policy == DuplicatePolicy.KEEP_ALL:
        clip_sets = keep_all_sets
    else:
        clip_sets = [
            ClipSet(timestamp=timestamp, start_time=dates[timestamp], files=grouped[timestamp])
            for timestamp in grouped
        ]
    clip_sets.sort(key=lambda item: (item.start_time, item.timestamp, tuple(sorted(str(path) for path in item.files.values()))))
    if not clip_sets:
        raise RuntimeError(f"No TeslaCam clips found under: {root}")
    return ScanResult(
        clip_sets=clip_sets,
        cameras=cameras_found,
        duplicate_file_count=duplicate_file_count,
        duplicate_timestamp_count=duplicate_timestamp_count,
    )


def scan_clips(root: Path) -> List[ClipSet]:
    return scan_source(root).clip_sets


def cameras_in_sets(clip_sets: Iterable[ClipSet]) -> Set[Camera]:
    cameras: Set[Camera] = set()
    for clip_set in clip_sets:
        cameras.update(clip_set.files.keys())
    return cameras


def _resolve_duplicate_path(existing: Path, candidate: Path, duplicate_policy: DuplicatePolicy) -> Path:
    if duplicate_policy == DuplicatePolicy.PREFER_NEWEST:
        existing_mtime = _safe_mtime(existing)
        candidate_mtime = _safe_mtime(candidate)
        if candidate_mtime > existing_mtime:
            return candidate
        if candidate_mtime == existing_mtime and str(candidate) < str(existing):
            return candidate
        return existing

    if str(candidate) < str(existing):
        return candidate
    return existing


def _safe_mtime(path: Path) -> float:
    try:
        return path.stat().st_mtime
    except OSError:
        return 0.0
