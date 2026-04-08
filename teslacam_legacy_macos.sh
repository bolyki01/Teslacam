#!/usr/bin/env zsh
emulate -L zsh
set -u
setopt PIPE_FAIL ERR_EXIT NO_NOMATCH

SCRIPT_DIR="${0:A:h}"
RESOURCE_DIR="$SCRIPT_DIR/TeslaCam/Resources"
FOUR_UP_SCRIPT="$RESOURCE_DIR/teslacam_4up_all_max.sh"
SIX_UP_SCRIPT="$RESOURCE_DIR/teslacam_6up_all_max.sh"
FFMPEG_BIN="$RESOURCE_DIR/ffmpeg_bin/ffmpeg"
FFPROBE_BIN="$RESOURCE_DIR/ffmpeg_bin/ffprobe"
OVERLAY_SRC="$SCRIPT_DIR/tools/TeslaCamOverlayGenerator.swift"
OVERLAY_BIN="$SCRIPT_DIR/bin/teslacam-overlay-generator"

usage() {
  cat <<'USAGE'
TeslaCam CLI Export

Interactive usage:
  ./teslacam.sh

Date/time format:
  DD/MM/YYYY-HH:MM:SS
  Example: 01/04/2026-18:30:00

Flow:
  1. Enter the folder containing TeslaCam videos.
  2. Enter export start date/time.
  3. Enter export end date/time.
  4. Enter extraction directory, or press Enter for the default:
     <source-folder>/output

The script reuses the bundled ffmpeg/ffprobe binaries, so it can run on a
bare macOS install without Homebrew.
USAGE
}

die() {
  print -u2 "ERROR: $*"
  exit 1
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || die "Required file missing: $path"
  [[ -x "$path" ]] || die "Required file is not executable: $path"
}

prompt_nonempty() {
  local prompt="$1"
  local answer=""
  while [[ -z "$answer" ]]; do
    printf "%s" "$prompt"
    IFS= read -r answer
    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"
  done
  print -- "$answer"
}

normalize_input_path() {
  local raw="$1"
  if [[ "$raw" == "~"* ]]; then
    raw="${~raw}"
  fi
  print -- "${raw:A}"
}

to_internal_timestamp() {
  local raw="$1"
  if [[ ! "$raw" =~ '^([0-9]{2})/([0-9]{2})/([0-9]{4})-([0-9]{2}):([0-9]{2}):([0-9]{2})$' ]]; then
    return 1
  fi
  local dd="${match[1]}"
  local mm="${match[2]}"
  local yyyy="${match[3]}"
  local hh="${match[4]}"
  local min="${match[5]}"
  local ss="${match[6]}"
  print -- "${yyyy}-${mm}-${dd}_${hh}-${min}-${ss}"
}

epoch_seconds() {
  local internal_ts="$1"
  date -j -f "%Y-%m-%d_%H-%M-%S" "$internal_ts" "+%s" 2>/dev/null
}

choose_renderer() {
  local input_dir="$1"
  if find "$input_dir" -type f \( -iname '*-left_pillar.mp4' -o -iname '*-left_pillar.mov' -o -iname '*-right_pillar.mp4' -o -iname '*-right_pillar.mov' -o -iname '*-left-pillar.mp4' -o -iname '*-left-pillar.mov' -o -iname '*-right-pillar.mp4' -o -iname '*-right-pillar.mov' \) -print -quit | grep -q .; then
    print -- "$SIX_UP_SCRIPT"
  else
    print -- "$FOUR_UP_SCRIPT"
  fi
}

collect_matching_files() {
  local source_dir="$1"
  local filtered_input_dir="$2"
  local start_epoch="$3"
  local end_epoch="$4"
  local matched_sets_file="$5"

  local count=0

  : > "$matched_sets_file"

  while IFS= read -r file; do
    local base="${file:t}"
    local stem="${base%.*}"
    if [[ ! "$stem" =~ '^([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2})-([A-Za-z0-9_-]+)$' ]]; then
      continue
    fi

    local clip_ts="${match[1]}"
    local clip_epoch
    clip_epoch="$(epoch_seconds "$clip_ts")" || continue
    if (( clip_epoch < start_epoch || clip_epoch > end_epoch )); then
      continue
    fi

    local dest="$filtered_input_dir/$base"
    if [[ ! -e "$dest" ]]; then
      ln "$file" "$dest" 2>/dev/null || cp "$file" "$dest"
      (( count += 1 ))
    fi
    print -- "$clip_ts" >> "$matched_sets_file"
  done < <(find "$source_dir" -type f \( -iname '*.mp4' -o -iname '*.mov' \) | sort)

  print -- "$count"
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  require_file "$FOUR_UP_SCRIPT"
  require_file "$SIX_UP_SCRIPT"
require_file "$FFMPEG_BIN"
  require_file "$FFPROBE_BIN"
  [[ -f "$OVERLAY_SRC" ]] || die "Missing telemetry overlay source: $OVERLAY_SRC"

  usage
  print ""

  local source_dir_raw
  source_dir_raw="$(prompt_nonempty "Folder containing TeslaCam videos: ")"
  local source_dir
  source_dir="$(normalize_input_path "$source_dir_raw")"
  [[ -d "$source_dir" ]] || die "Source folder does not exist: $source_dir"

  local start_raw=""
  local start_ts=""
  until start_ts="$(to_internal_timestamp "$start_raw" 2>/dev/null)"; do
    start_raw="$(prompt_nonempty "Export start (DD/MM/YYYY-HH:MM:SS): ")"
    if ! start_ts="$(to_internal_timestamp "$start_raw" 2>/dev/null)"; then
      print -u2 "Invalid format. Use DD/MM/YYYY-HH:MM:SS, for example 01/04/2026-18:30:00"
    fi
  done

  local end_raw=""
  local end_ts=""
  until end_ts="$(to_internal_timestamp "$end_raw" 2>/dev/null)"; do
    end_raw="$(prompt_nonempty "Export end   (DD/MM/YYYY-HH:MM:SS): ")"
    if ! end_ts="$(to_internal_timestamp "$end_raw" 2>/dev/null)"; then
      print -u2 "Invalid format. Use DD/MM/YYYY-HH:MM:SS, for example 01/04/2026-18:45:00"
    fi
  done

  local start_epoch
  local end_epoch
  start_epoch="$(epoch_seconds "$start_ts")" || die "Failed to parse start time."
  end_epoch="$(epoch_seconds "$end_ts")" || die "Failed to parse end time."
  (( end_epoch >= start_epoch )) || die "End time must be after or equal to start time."

  local default_output_dir="$source_dir/output"
  printf "Extraction directory [%s]: " "$default_output_dir"
  local output_dir_raw=""
  IFS= read -r output_dir_raw
  output_dir_raw="${output_dir_raw#"${output_dir_raw%%[![:space:]]*}"}"
  output_dir_raw="${output_dir_raw%"${output_dir_raw##*[![:space:]]}"}"
  local output_dir
  if [[ -z "$output_dir_raw" ]]; then
    output_dir="$default_output_dir"
  else
    output_dir="$(normalize_input_path "$output_dir_raw")"
  fi
  mkdir -p "$output_dir" || die "Failed to create output directory: $output_dir"

  local temp_root
  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/teslacam_cli.XXXXXX")"
  local filtered_input_dir="$temp_root/input"
  local work_dir="$temp_root/work"
  local overlay_dir="$temp_root/overlays"
  local matched_sets_file="$temp_root/matched_sets.txt"
  mkdir -p "$filtered_input_dir" "$work_dir" "$overlay_dir"
  trap 'rm -rf "$temp_root"' EXIT

  print ""
  print "Filtering source clips..."

  local matched_files
  matched_files="$(collect_matching_files "$source_dir" "$filtered_input_dir" "$start_epoch" "$end_epoch" "$matched_sets_file")"
  (( matched_files > 0 )) || die "No clips matched the requested date/time range."

  local unique_sets
  unique_sets="$(sort -u "$matched_sets_file" | wc -l | tr -d ' ')"
  (( unique_sets > 0 )) || die "No valid TeslaCam timestamp sets were found in the selected range."

  local renderer
  renderer="$(choose_renderer "$filtered_input_dir")"
  local layout_name
  if [[ "$renderer" == "$SIX_UP_SCRIPT" ]]; then
    layout_name="6-up"
  else
    layout_name="4-up"
  fi

  local output_file="$output_dir/teslacam_${start_ts}_to_${end_ts}_prores_hq.mov"

  print "Matched files: $matched_files"
  print "Matched minute sets: $unique_sets"
  print "Layout: $layout_name"
  print "Output: $output_file"
  print ""
  print "Preparing telemetry overlays..."
  ensure_overlay_generator
  "$OVERLAY_BIN" "$filtered_input_dir" "$overlay_dir"
  print "Telemetry overlays ready."
  print ""
  print "Starting export..."

  PRESET="PRORES_HQ" \
  WORKDIR="$work_dir" \
  FFMPEG="$FFMPEG_BIN" \
  FFPROBE="$FFPROBE_BIN" \
  OVERLAY_DIR="$overlay_dir" \
  "$renderer" "$filtered_input_dir" "$output_file"

  print ""
  print "Export complete:"
  print "$output_file"
}

ensure_overlay_generator() {
  if [[ -x "$OVERLAY_BIN" && "$OVERLAY_BIN" -nt "$OVERLAY_SRC" ]]; then
    return
  fi

  if command -v xcrun >/dev/null 2>&1; then
    print "Compiling telemetry overlay helper..."
    xcrun swiftc -parse-as-library -O -o "$OVERLAY_BIN" "$OVERLAY_SRC" || die "Failed to compile telemetry overlay helper."
    return
  fi

  [[ -x "$OVERLAY_BIN" ]] || die "Telemetry helper is not available. Build a release package that includes $OVERLAY_BIN, or install Xcode Command Line Tools so the helper can be compiled."
}

main "$@"
