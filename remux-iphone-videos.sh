#!/usr/bin/env bash
# Prepare iPhone videos for Plex (macOS / Linux version of remux-iphone-videos.ps1).
# - Files WITH an APAC (spatial audio) track or Dolby Vision: remux, keep HEVC video + AAC stereo,
#   drop APAC, the Dolby Vision layer and the metadata tracks. No re-encoding: quality stays bit-identical.
# - Other files: copied as is.
# File names and extensions are kept exactly as in the source (.MOV stays .MOV).
# Originals are never modified.
#
# Usage:
#   ./remux-iphone-videos.sh "$HOME/Videos/iPhone" "$HOME/Videos/iPhone (Plex)"
#   ./remux-iphone-videos.sh --recheck "$HOME/Videos/iPhone" "$HOME/Videos/iPhone (Plex)"
#
# Safe to re-run: files that already exist in the destination are skipped.
# With --recheck, existing files are inspected and redone if they still have APAC or Dolby Vision
# (e.g. copied as is by an older version of this script). Slower: every existing file is probed.
# Works with the bash 3.2 that ships with macOS.

recheck=''
if [ "$1" = "--recheck" ]; then recheck=1; shift; fi
if [ $# -ne 2 ]; then
    echo "Usage: $0 [--recheck] SOURCE DEST" >&2
    exit 1
fi

if [ -t 1 ]; then
    red=$'\033[31m'; green=$'\033[32m'; yellow=$'\033[33m'; reset=$'\033[0m'
else
    red=''; green=''; yellow=''; reset=''
fi

if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
    echo "${red}ffmpeg/ffprobe not found. Install with: brew install ffmpeg (macOS) or your package manager (Linux)${reset}" >&2
    exit 1
fi
if [ ! -d "$1" ]; then
    echo "${red}Source folder not found: $1${reset}" >&2
    exit 1
fi

created=''; [ -d "$2" ] || created=1
mkdir -p "$2" || exit 1
# Clear CDPATH, otherwise cd prints the folder and it ends up in the path
src_root=$(CDPATH='' cd -- "$1" && pwd -P) || exit 1
dest=$(CDPATH='' cd -- "$2" && pwd -P) || exit 1
log="$dest/remux-errors.log"

# A destination inside the source would be scanned too, nesting copies deeper on every run
src_prefix="${src_root%/}/"    # "/" stays "/", so a root source matches everything
case "$dest/" in
    "$src_prefix"*)
        if [ -n "$created" ]; then rmdir "$dest"; fi
        echo "${red}Destination must not be the source folder or inside it: $dest${reset}" >&2
        exit 1
        ;;
esac

# Start each run clean: fresh error log, and remove unfinished temp files from an interrupted run
rm -f "$log"
# (! -type d also catches symlinks; rm removes the link itself, never its target)
find "$dest" -name '*.part' ! -type d -exec rm -f {} +

# Skip "._*" files: macOS metadata companions on non-Mac drives and network shares, not videos.
# The list goes through a temp file so a failed scan (unreadable folder, lost share) is noticed.
list=$(mktemp) || exit 1
scan_ok=1
find "$src_root" -type f \( -iname '*.mov' -o -iname '*.mp4' \) ! -name '._*' -print0 > "$list" || scan_ok=''
files=()
while IFS= read -r -d '' f; do
    files+=("$f")
done < "$list"
rm -f "$list"

# Stream list of a file: codec, tag and side data (such as the Dolby Vision record) per stream
probe() {
    ffprobe -v error -show_entries stream=codec_name,codec_tag_string:stream_side_data=side_data_type -of csv=p=0 "$1" </dev/null
}

# Plex struggles with APAC spatial audio and with iPhone Dolby Vision files (long start, no video)
needs_remux() {
    printf '%s\n' "$1" | grep -qE 'apac|DOVI'
}

total=${#files[@]}
i=0; remuxed=0; replaced=0; copied=0; skipped=0; failed=0
echo "Found $total .mov/.mp4 files in $src_root"
if [ -n "$recheck" ]; then echo "Rechecking files that already exist in $dest, this takes a while"; fi
if [ -z "$scan_ok" ]; then
    # Process what was found anyway: a re-run picks up the rest once the folders are readable
    echo "scan failed: some folders in $src_root could not be read" >> "$log"
    echo "${red}Some folders could not be read (see errors above), their videos are not included${reset}"
    failed=$((failed + 1))
fi

for f in "${files[@]}"; do
    i=$((i + 1))
    rel=${f#"$src_root"/}
    out="$dest/$rel"          # same name and extension as the original
    mkdir -p "$(dirname "$out")"

    # Already done? With --recheck, redo it if it still needs remuxing (or can't be read)
    replace=''
    if [ -e "$out" ]; then
        if [ -z "$recheck" ] || { existing=$(probe "$out") && ! needs_remux "$existing"; }; then
            skipped=$((skipped + 1))
            continue
        fi
        replace=' (replacing)'
    fi

    tmp="$out.part"

    if ! streams=$(probe "$f"); then
        echo "ffprobe failed: $f" >> "$log"
        echo "[$i/$total] $rel  ${red}FAILED (ffprobe)${reset}"
        failed=$((failed + 1))
        continue
    fi

    if ! needs_remux "$streams"; then
        # Nothing Plex has trouble with: plain copy
        echo "[$i/$total] copy:  $rel$replace"
        if cp "$f" "$tmp" && touch -r "$f" "$tmp" && mv "$tmp" "$out"; then
            copied=$((copied + 1))
            if [ -n "$replace" ]; then replaced=$((replaced + 1)); fi
        else
            rm -f "$tmp"
            echo "copy failed: $f" >> "$log"
            echo "  ${red}FAILED${reset}"
            failed=$((failed + 1))
        fi
        continue
    fi

    # Has APAC or Dolby Vision: remux into the same container type as the original
    echo "[$i/$total] remux: $rel$replace"
    case "$f" in
        *.[mM][pP]4) fmt=mp4 ;;
        *)           fmt=mov ;;
    esac

    if ffmpeg -hide_banner -loglevel error -nostdin -y \
        -i "$f" \
        -map 0:v:0 -map "0:a:0?" \
        -c copy -tag:v hvc1 \
        -map_metadata 0 -movflags "+faststart+use_metadata_tags" \
        -f "$fmt" "$tmp" &&
        touch -c -r "$f" "$tmp" && mv "$tmp" "$out"; then
        remuxed=$((remuxed + 1))
        if [ -n "$replace" ]; then replaced=$((replaced + 1)); fi
    else
        rm -f "$tmp"
        echo "remux failed: $f" >> "$log"
        echo "  ${red}FAILED${reset}"
        failed=$((failed + 1))
    fi
done

echo ""
echo "${green}Done. Remuxed: $remuxed, copied as is: $copied, of these replacing older copies: $replaced, already existed: $skipped, failed: $failed${reset}"
if [ "$failed" -gt 0 ]; then
    echo "${yellow}Failed files are listed in: $log${reset}"
    exit 1
fi
