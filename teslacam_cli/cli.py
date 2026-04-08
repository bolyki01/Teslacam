from __future__ import annotations

import argparse
import shutil
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Iterable, Optional

from .composer import (
    compose,
    prepare_workdir,
    probe_dimensions_for_selection,
    probe_selection_fps,
    select_clip_sets,
)
from .ffmpeg_tools import ToolResolutionError, choose_encoder, probe_duration, resolve_tools
from .layouts import PROFILE_LABELS, build_layout, detect_layout_kind, fill_missing_dimensions
from .models import Camera, ComposePlan
from .scanner import cameras_in_sets, format_clip_timestamp, parse_clip_timestamp, scan_clips


@dataclass(frozen=True)
class RunConfig:
    source_dir: Path
    output_file: Path
    start_time: datetime
    end_time: datetime
    profile: str
    mode: str
    ffmpeg: Path
    ffprobe: Path
    workdir: Path
    keep_workdir: bool
    x265_preset: str
    loglevel: str



def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="teslacam-cli",
        description="Cross-platform TeslaCam CLI composer. Default output: H.265/HEVC MP4 in lossless mode.",
    )
    parser.add_argument("source", nargs="?", help="TeslaCam source folder")
    parser.add_argument("-o", "--output", help="Output MP4 path")
    parser.add_argument("--start", help="Start time. Accepts DD/MM/YYYY-HH:MM:SS, YYYY-MM-DD HH:MM:SS, YYYY-MM-DD_HH-MM-SS")
    parser.add_argument("--end", help="End time. Accepts DD/MM/YYYY-HH:MM:SS, YYYY-MM-DD HH:MM:SS, YYYY-MM-DD_HH-MM-SS")
    parser.add_argument(
        "--profile",
        choices=sorted(PROFILE_LABELS.keys()),
        default="auto",
        help="Car/layout profile. Auto uses clip detection. legacy4 forces 4-camera. sixcam forces 6-camera.",
    )
    parser.add_argument(
        "--mode",
        choices=["lossless", "quality"],
        default="lossless",
        help="lossless = x265 lossless HEVC MP4. quality = x265 CRF 6 HEVC MP4.",
    )
    parser.add_argument("--x265-preset", default="medium", help="x265 preset for encode speed/compression ratio")
    parser.add_argument("--ffmpeg", help="Path to ffmpeg")
    parser.add_argument("--ffprobe", help="Path to ffprobe")
    parser.add_argument("--workdir", help="Working directory for intermediate parts")
    parser.add_argument("--keep-workdir", action="store_true", help="Keep intermediate files")
    parser.add_argument("--loglevel", default="info", help="ffmpeg loglevel (default: info)")
    parser.add_argument("--interactive", action="store_true", help="Force prompt mode even when arguments are supplied")
    parser.add_argument("--dry-run", action="store_true", help="Scan and print resolved plan without rendering")
    return parser



def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        repo_root = Path(__file__).resolve().parent.parent
        interactive = args.interactive or args.source is None
        ffmpeg, ffprobe = resolve_tools(repo_root, args.ffmpeg, args.ffprobe)

        if interactive:
            config = prompt_run_config(ffmpeg=ffmpeg, ffprobe=ffprobe)
        else:
            source_dir = Path(args.source).expanduser().resolve()
            clip_sets = scan_clips(source_dir)
            start_default, end_default = dataset_range(clip_sets, ffprobe)
            start_time = parse_user_datetime(args.start) if args.start else start_default
            end_time = parse_user_datetime(args.end) if args.end else end_default
            output_file = resolve_output_path(source_dir, args.output, args.mode, start_time, end_time)
            workdir, workdir_was_explicit = prepare_workdir(Path(args.workdir).expanduser().resolve() if args.workdir else None)
            config = RunConfig(
                source_dir=source_dir,
                output_file=output_file,
                start_time=start_time,
                end_time=end_time,
                profile=args.profile,
                mode=args.mode,
                ffmpeg=ffmpeg,
                ffprobe=ffprobe,
                workdir=workdir,
                keep_workdir=args.keep_workdir or workdir_was_explicit,
                x265_preset=args.x265_preset,
                loglevel=args.loglevel,
            )

        if config.end_time <= config.start_time:
            raise RuntimeError("End time must be after start time.")

        clip_sets = scan_clips(config.source_dir)
        selected_sets = select_clip_sets(clip_sets, config.start_time, config.end_time, config.ffprobe)
        if not selected_sets:
            raise RuntimeError("No clips overlap the requested time range.")

        available_cameras = cameras_in_sets(selected_sets_to_clip_sets(selected_sets))
        layout_kind = detect_layout_kind(config.profile, available_cameras)
        probed_dimensions = probe_dimensions_for_selection(config.ffprobe, selected_sets)
        dimensions = fill_missing_dimensions(layout_kind, probed_dimensions)
        layout = build_layout(layout_kind, dimensions)
        fps = probe_selection_fps(config.ffprobe, selected_sets)
        encoder = choose_encoder(config.ffmpeg, config.mode, config.x265_preset)

        print_summary(
            source_dir=config.source_dir,
            output_file=config.output_file,
            start_time=config.start_time,
            end_time=config.end_time,
            layout=layout.kind.value,
            mode=encoder.label,
            camera_dimensions=dimensions,
            sets=len(selected_sets),
        )

        if args.dry_run:
            if not config.keep_workdir and config.workdir.exists():
                shutil.rmtree(config.workdir, ignore_errors=True)
            return 0

        plan = ComposePlan(
            source_dir=config.source_dir,
            output_file=config.output_file,
            ffmpeg=config.ffmpeg,
            ffprobe=config.ffprobe,
            layout=layout,
            fps=fps,
            encoder=encoder,
            selected_sets=selected_sets,
            dimensions_by_camera=dimensions,
            workdir=config.workdir,
            keep_workdir=config.keep_workdir,
            loglevel=config.loglevel,
        )
        output = compose(plan)
        print(f"Done: {output}")
        if config.keep_workdir:
            print(f"Workdir kept: {config.workdir}")
        elif config.workdir.exists():
            shutil.rmtree(config.workdir, ignore_errors=True)
        return 0
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        return 130
    except (RuntimeError, FileNotFoundError, ToolResolutionError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1



def selected_sets_to_clip_sets(selected_sets):
    for selected in selected_sets:
        yield selected.clip_set



def parse_user_datetime(value: str) -> datetime:
    candidates = [
        "%d/%m/%Y-%H:%M:%S",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d_%H-%M-%S",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%dT%H:%M",
        "%Y-%m-%d %H:%M",
        "%d/%m/%Y-%H:%M",
    ]
    last_error = None
    for fmt in candidates:
        try:
            return datetime.strptime(value.strip(), fmt)
        except ValueError as exc:
            last_error = exc
    raise RuntimeError(
        "Could not parse datetime. Use DD/MM/YYYY-HH:MM:SS, YYYY-MM-DD HH:MM:SS, or YYYY-MM-DD_HH-MM-SS."
    ) from last_error



def dataset_range(clip_sets, ffprobe: Path) -> tuple[datetime, datetime]:
    first = clip_sets[0]
    last = clip_sets[-1]
    last_source = next(iter(last.files.values()), None)
    last_duration = probe_duration(ffprobe, last_source) if last_source else 60.0
    return first.start_time, last.start_time + timedelta(seconds=last_duration)



def default_output_filename(mode: str, start_time: datetime, end_time: datetime) -> str:
    start_label = format_clip_timestamp(start_time)
    end_label = format_clip_timestamp(end_time)
    return f"teslacam_{mode}_{start_label}_to_{end_label}.mp4"



def resolve_output_path(source_dir: Path, output_arg: Optional[str], mode: str, start_time: datetime, end_time: datetime) -> Path:
    if output_arg:
        path = Path(output_arg).expanduser().resolve()
        if path.suffix.lower() != ".mp4":
            path = path.with_suffix(".mp4")
        return path
    output_dir = source_dir / "output"
    output_dir.mkdir(parents=True, exist_ok=True)
    return (output_dir / default_output_filename(mode, start_time, end_time)).resolve()



def prompt_run_config(ffmpeg: Path, ffprobe: Path) -> RunConfig:
    while True:
        raw_source = input("TeslaCam source folder: ").strip()
        if raw_source:
            source_dir = Path(raw_source).expanduser().resolve()
            if source_dir.exists() and source_dir.is_dir():
                break
        print("Invalid folder.")

    clip_sets = scan_clips(source_dir)
    start_default, end_default = dataset_range(clip_sets, ffprobe)
    cameras = cameras_in_sets(clip_sets)
    print(
        f"Found {len(clip_sets)} clip sets | "
        f"Range: {start_default} -> {end_default} | "
        f"Cameras: {', '.join(camera.display_name for camera in sorted(cameras, key=lambda item: item.value))}"
    )

    print("Car/layout profile:")
    print("  1) auto    - Auto-detect from clips")
    print("  2) legacy4 - Tesla legacy 4-camera layout")
    print("  3) sixcam  - Tesla 6-camera layout")
    profile = prompt_choice("Profile [auto]: ", default="auto", allowed={"auto", "legacy4", "sixcam", "1", "2", "3"})
    profile = {"1": "auto", "2": "legacy4", "3": "sixcam"}.get(profile, profile)

    start_time = prompt_datetime(
        prompt=f"Start [{start_default.strftime('%d/%m/%Y-%H:%M:%S')}]: ",
        default=start_default,
    )
    end_time = prompt_datetime(
        prompt=f"End   [{end_default.strftime('%d/%m/%Y-%H:%M:%S')}]: ",
        default=end_default,
    )

    print("Output mode:")
    print("  1) lossless - H.265 MP4, x265 lossless, very large files")
    print("  2) quality  - H.265 MP4, x265 CRF 6, smaller files")
    mode = prompt_choice("Mode [lossless]: ", default="lossless", allowed={"lossless", "quality", "1", "2"})
    mode = {"1": "lossless", "2": "quality"}.get(mode, mode)

    default_output = resolve_output_path(source_dir, None, mode, start_time, end_time)
    raw_output = input(f"Output MP4 [{default_output}]: ").strip()
    output_file = Path(raw_output).expanduser().resolve() if raw_output else default_output

    raw_workdir = input("Workdir [temporary]: ").strip()
    workdir, workdir_was_explicit = prepare_workdir(Path(raw_workdir).expanduser().resolve() if raw_workdir else None)

    raw_keep = input("Keep intermediate files? [N]: ").strip().lower()
    keep_workdir = workdir_was_explicit or raw_keep in {"y", "yes"}

    raw_preset = input("x265 preset [medium]: ").strip() or "medium"

    return RunConfig(
        source_dir=source_dir,
        output_file=output_file,
        start_time=start_time,
        end_time=end_time,
        profile=profile,
        mode=mode,
        ffmpeg=ffmpeg,
        ffprobe=ffprobe,
        workdir=workdir,
        keep_workdir=keep_workdir,
        x265_preset=raw_preset,
        loglevel="info",
    )



def prompt_datetime(prompt: str, default: datetime) -> datetime:
    while True:
        value = input(prompt).strip()
        if not value:
            return default
        try:
            return parse_user_datetime(value)
        except RuntimeError as exc:
            print(exc)



def prompt_choice(prompt: str, default: str, allowed: set[str]) -> str:
    while True:
        value = input(prompt).strip().lower()
        if not value:
            return default
        if value in allowed:
            return value
        print(f"Allowed: {', '.join(sorted(allowed))}")



def print_summary(
    source_dir: Path,
    output_file: Path,
    start_time: datetime,
    end_time: datetime,
    layout: str,
    mode: str,
    camera_dimensions: dict[Camera, object],
    sets: int,
) -> None:
    dimension_text = ", ".join(
        f"{camera.value}={dims.width}x{dims.height}"
        for camera, dims in sorted(camera_dimensions.items(), key=lambda item: item[0].value)
    )
    print("Plan:")
    print(f"  Source: {source_dir}")
    print(f"  Output: {output_file}")
    print(f"  Range:  {start_time} -> {end_time}")
    print(f"  Layout: {layout} | Sets: {sets}")
    print(f"  Mode:   {mode}")
    print(f"  Cells:  {dimension_text}")


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
