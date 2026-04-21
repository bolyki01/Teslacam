from __future__ import annotations

import shutil
from datetime import datetime, timedelta
from pathlib import Path
from tempfile import mkdtemp
from typing import Dict, Iterable, List, Optional

from .ffmpeg_tools import ffconcat_path, probe_dimensions, probe_duration, probe_fps, probe_has_video_stream, run_command
from .models import Camera, ClipSet, ComposePlan, Dimensions, LayoutSpec, MIXED_CAMERA_ORDER, SelectedSet


def clip_set_duration(
    clip_set: ClipSet,
    ffprobe: Path,
    duration_cache: Optional[Dict[Path, float]] = None,
) -> float:
    max_duration = 0.0
    for clip_path in clip_set.files.values():
        if not clip_path.exists():
            continue
        duration = duration_cache.get(clip_path) if duration_cache is not None else None
        if duration is None:
            duration = probe_duration(ffprobe, clip_path)
            if duration_cache is not None:
                duration_cache[clip_path] = duration
        max_duration = max(max_duration, duration)
    return max_duration or 60.0


def select_clip_sets(
    clip_sets: Iterable[ClipSet],
    start_time: datetime,
    end_time: datetime,
    ffprobe: Path,
) -> List[SelectedSet]:
    selected: List[SelectedSet] = []
    duration_cache: Dict[Path, float] = {}

    for clip_set in clip_sets:
        duration = clip_set_duration(clip_set, ffprobe, duration_cache)
        clip_end = clip_set.start_time + timedelta(seconds=duration)
        if clip_set.start_time >= end_time or clip_end <= start_time:
            continue
        trim_start = max(0.0, (start_time - clip_set.start_time).total_seconds())
        trim_end = min(duration, (end_time - clip_set.start_time).total_seconds())
        if trim_end - trim_start <= 0.001:
            continue
        selected.append(
            SelectedSet(
                clip_set=clip_set,
                duration=duration,
                trim_start=trim_start,
                trim_end=trim_end,
            )
        )
    return selected



def first_existing_clip(clip_set: ClipSet, ffprobe: Optional[Path] = None) -> Optional[Path]:
    for camera in MIXED_CAMERA_ORDER:
        candidate = clip_set.files.get(camera)
        if not candidate or not candidate.exists():
            continue
        if ffprobe is not None and not probe_has_video_stream(ffprobe, candidate):
            continue
        return candidate
    return None



def probe_dimensions_for_selection(
    ffprobe: Path,
    selected_sets: Iterable[SelectedSet],
) -> Dict[Camera, Dimensions]:
    dimensions: Dict[Camera, Dimensions] = {}
    for selected in selected_sets:
        for camera, clip_path in selected.clip_set.files.items():
            if camera in dimensions:
                continue
            probed = probe_dimensions(ffprobe, clip_path)
            if probed is not None:
                dimensions[camera] = probed
    return dimensions



def probe_selection_fps(ffprobe: Path, selected_sets: Iterable[SelectedSet]) -> float:
    for selected in selected_sets:
        source = first_existing_clip(selected.clip_set, ffprobe=ffprobe)
        if source is not None:
            return probe_fps(ffprobe, source)
    return 36.027



def prepare_workdir(workdir: Optional[Path]) -> tuple[Path, bool]:
    if workdir is None:
        created = Path(mkdtemp(prefix="teslacam_cli_"))
        return created, False
    workdir.mkdir(parents=True, exist_ok=True)
    return workdir.resolve(), True



def compose(plan: ComposePlan) -> Path:
    parts_dir = plan.workdir / "parts"
    parts_dir.mkdir(parents=True, exist_ok=True)
    concat_file = plan.workdir / "concat.txt"
    part_paths: List[Path] = []
    clip_readability = collect_clip_readability(plan.ffprobe, plan.selected_sets)
    unreadable_paths = sorted(path for path, readable in clip_readability.items() if not readable)

    print(f"Using ffmpeg: {plan.ffmpeg}")
    print(f"Using ffprobe: {plan.ffprobe}")
    print(
        f"Canvas: {plan.layout.canvas_width}x{plan.layout.canvas_height} | "
        f"Layout: {plan.layout.kind.value} | FPS: {plan.fps:.3f} | Mode: {plan.encoder.label}"
    )
    print(f"Clip sets selected: {len(plan.selected_sets)}")
    if unreadable_paths:
        print(f"Warning: {len(unreadable_paths)} unreadable or missing clip(s) will render as black placeholders.")
        for clip_path in unreadable_paths[:5]:
            print(f"  - {clip_path}")
        if len(unreadable_paths) > 5:
            print(f"  ... {len(unreadable_paths) - 5} more")

    for index, selected in enumerate(plan.selected_sets, start=1):
        part_path = parts_dir / f"{index:06d}_{selected.clip_set.timestamp}.{plan.encoder.output_extension}"
        print(
            f"[{index}/{len(plan.selected_sets)}] {selected.clip_set.timestamp} "
            f"trim {selected.trim_start:.3f}s -> {selected.trim_end:.3f}s"
        )
        command = build_part_command(plan, selected, part_path, clip_readability)
        run_command(command)
        part_paths.append(part_path)

    with concat_file.open("w", encoding="utf-8", newline="\n") as handle:
        for part_path in part_paths:
            handle.write(f"file '{ffconcat_path(part_path)}'\n")

    plan.output_file.parent.mkdir(parents=True, exist_ok=True)
    concat_command = [
        str(plan.ffmpeg),
        "-y",
        "-hide_banner",
        "-loglevel",
        plan.loglevel,
        "-f",
        "concat",
        "-safe",
        "0",
        "-i",
        str(concat_file),
        "-c",
        "copy",
        "-movflags",
        "+faststart",
        str(plan.output_file),
    ]
    print("Concatenating final MP4...")
    run_command(concat_command)
    return plan.output_file



def build_part_command(
    plan: ComposePlan,
    selected: SelectedSet,
    part_path: Path,
    clip_readability: Optional[Dict[Path, bool]] = None,
) -> List[str]:
    input_args: List[str] = []
    filter_parts: List[str] = []
    labels: List[str] = []
    fps_text = _fmt_float(plan.fps)
    trim_start = _fmt_float(selected.trim_start)
    trim_end = _fmt_float(selected.trim_end)

    for input_index, camera in enumerate(plan.layout.cameras):
        clip_path = selected.clip_set.files.get(camera)
        cell = plan.layout.cell_by_camera[camera]
        clip_is_usable = bool(
            clip_path
            and clip_path.exists()
            and (clip_readability.get(clip_path, True) if clip_readability is not None else True)
        )
        if clip_is_usable and clip_path is not None:
            input_args.extend(["-i", str(clip_path)])
        else:
            input_args.extend(
                [
                    "-f",
                    "lavfi",
                    "-t",
                    _fmt_float(selected.duration),
                    "-r",
                    fps_text,
                    "-i",
                    f"color=size={cell.width}x{cell.height}:rate={fps_text}:color=black",
                ]
            )
        label = f"v{input_index}"
        labels.append(f"[{label}]")
        filter_parts.append(
            "[{}:v]trim=start={}:end={},setpts=PTS-STARTPTS,".format(input_index, trim_start, trim_end)
            + "scale={}:{}:flags=lanczos:force_original_aspect_ratio=decrease,".format(cell.width, cell.height)
            + "pad={}:{}:(ow-iw)/2:(oh-ih)/2:black,setsar=1[{}]".format(cell.width, cell.height, label)
        )

    layout_tokens = []
    for camera in plan.layout.cameras:
        cell = plan.layout.cell_by_camera[camera]
        layout_tokens.append(f"{cell.x}_{cell.y}")
    filter_parts.append(
        "{}xstack=inputs={}:layout={}:fill=black,format=yuv420p[vout]".format(
            "".join(labels),
            len(labels),
            "|".join(layout_tokens),
        )
    )

    return [
        str(plan.ffmpeg),
        "-y",
        "-hide_banner",
        "-loglevel",
        plan.loglevel,
        *input_args,
        "-filter_complex",
        ";".join(filter_parts),
        "-map",
        "[vout]",
        "-an",
        "-r",
        fps_text,
        *plan.encoder.args,
        str(part_path),
    ]


def collect_clip_readability(ffprobe: Path, selected_sets: Iterable[SelectedSet]) -> Dict[Path, bool]:
    readability: Dict[Path, bool] = {}
    for selected in selected_sets:
        for clip_path in selected.clip_set.files.values():
            if clip_path in readability:
                continue
            readability[clip_path] = clip_path.exists() and probe_has_video_stream(ffprobe, clip_path)
    return readability



def _fmt_float(value: float) -> str:
    text = f"{value:.6f}"
    text = text.rstrip("0").rstrip(".")
    return text or "0"
