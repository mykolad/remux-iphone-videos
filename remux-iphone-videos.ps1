# Prepare iPhone videos for Plex.
# - Files WITH an APAC (spatial audio) track or Dolby Vision: remux, keep HEVC video + AAC stereo,
#   drop APAC, the Dolby Vision layer and the metadata tracks. No re-encoding: quality stays bit-identical.
# - Other files: copied as is.
# File names and extensions are kept exactly as in the source (.MOV stays .MOV).
# Originals are never modified.
#
# Usage (in PowerShell, from the folder where this script is saved):
#   powershell -ExecutionPolicy Bypass -File .\remux-iphone-videos.ps1
# or with your own folders:
#   powershell -ExecutionPolicy Bypass -File .\remux-iphone-videos.ps1 -Source "E:\Phone Videos" -Dest "\\NAS\Videos\iPhone"
#
# Safe to re-run: files that already exist in Dest are skipped.
# With -Recheck, existing files are inspected and redone if they still have APAC or Dolby Vision
# (e.g. copied as is by an older version of this script). Slower: every existing file is probed.
# Files created by the previous version of this script with a different letter case
# (e.g. ".mov" instead of ".MOV") are renamed to match the source.

param(
    [string]$Source = "D:\Videos\iPhone",
    [string]$Dest   = "D:\Videos\iPhone (Plex)",
    [switch]$Recheck
)

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue) -or -not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    Write-Host "ffmpeg/ffprobe not found. Install with: winget install Gyan.FFmpeg (then reopen PowerShell)" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $Source)) {
    Write-Host "Source folder not found: $Source" -ForegroundColor Red
    exit 1
}

$srcRoot = (Resolve-Path -LiteralPath $Source).ProviderPath.TrimEnd('\')
$created = -not (Test-Path -LiteralPath $Dest)
New-Item -ItemType Directory -Path $Dest -Force | Out-Null
$destRoot = (Resolve-Path -LiteralPath $Dest).ProviderPath.TrimEnd('\')
$log = Join-Path $Dest "remux-errors.log"

# A destination inside the source would be scanned too, nesting copies deeper on every run
if ("$destRoot\".StartsWith("$srcRoot\", [StringComparison]::OrdinalIgnoreCase)) {
    if ($created) { Remove-Item -LiteralPath $destRoot }
    Write-Host "Destination must not be the source folder or inside it: $destRoot" -ForegroundColor Red
    exit 1
}

# Start each run clean: fresh error log, and remove unfinished temp files from an interrupted run
Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $Dest -Recurse -File -Filter "*.part" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

function Copy-Timestamp($from, $toPath) {
    $item = Get-Item -LiteralPath $toPath
    $item.CreationTime  = $from.CreationTime
    $item.LastWriteTime = $from.LastWriteTime
}

# Stream list of a file: codec, tag and side data (such as the Dolby Vision record) per stream
function Get-StreamInfo($path) {
    & ffprobe -v error -show_entries "stream=codec_name,codec_tag_string:stream_side_data=side_data_type" -of csv=p=0 $path
}

# Plex struggles with APAC spatial audio and with iPhone Dolby Vision files (long start, no video)
function Test-NeedsRemux($streams) {
    [bool]($streams -match 'apac|DOVI')
}

$files = Get-ChildItem -LiteralPath $srcRoot -Recurse -File -ErrorVariable scanErrors |
    Where-Object { $_.Extension -ieq ".mov" -or $_.Extension -ieq ".mp4" }

$total = $files.Count
$i = 0; $remuxed = 0; $replaced = 0; $copied = 0; $skipped = 0; $renamed = 0; $failed = 0
Write-Host "Found $total .mov/.mp4 files in $srcRoot"
if ($Recheck) { Write-Host "Rechecking files that already exist in $destRoot, this takes a while" }
if ($scanErrors) {
    # Process what was found anyway: a re-run picks up the rest once the folders are readable
    Add-Content -LiteralPath $log -Value "scan failed: some folders in $srcRoot could not be read"
    Write-Host "Some folders could not be read (see errors above), their videos are not included" -ForegroundColor Red
    $failed++
}

foreach ($f in $files) {
    $i++
    $rel    = $f.FullName.Substring($srcRoot.Length).TrimStart('\')
    $out    = Join-Path $Dest $rel          # same name and extension as the original
    $outDir = Split-Path $out -Parent
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    # A folder with the video's name would swallow the file on the final move
    if (Test-Path -LiteralPath $out -PathType Container) {
        Add-Content -LiteralPath $log -Value "destination is a folder: $out"
        Write-Host "[$i/$total] $rel  FAILED (destination is a folder)" -ForegroundColor Red
        $failed++
        continue
    }

    # Already done? (Windows paths are case-insensitive, so look up the real on-disk name)
    # With -Recheck, redo it if it still needs remuxing (or can't be read)
    $replace = ""
    $existing = Get-ChildItem -LiteralPath $outDir -File | Where-Object { $_.Name -ieq $f.Name } | Select-Object -First 1
    if ($existing) {
        if ($existing.Name -cne $f.Name) {
            # Case-only rename has to go through a temporary name
            $tmpName = Join-Path $outDir ($f.Name + ".renaming")
            [IO.File]::Move($existing.FullName, $tmpName)
            [IO.File]::Move($tmpName, $out)
            Write-Host "[$i/$total] renamed: $($existing.Name) -> $($f.Name)"
            $renamed++
        }
        $existingStreams = if ($Recheck) { Get-StreamInfo $out }
        if (-not $Recheck -or ($LASTEXITCODE -eq 0 -and -not (Test-NeedsRemux $existingStreams))) {
            $skipped++
            continue
        }
        $replace = " (replacing)"
    }

    $tmp = "$out.part"

    $streams = Get-StreamInfo $f.FullName
    if ($LASTEXITCODE -ne 0) {
        Add-Content -LiteralPath $log -Value "ffprobe failed: $($f.FullName)"
        Write-Host "[$i/$total] $rel  FAILED (ffprobe)" -ForegroundColor Red
        $failed++
        continue
    }

    if (-not (Test-NeedsRemux $streams)) {
        # Nothing Plex has trouble with: plain copy
        Write-Host "[$i/$total] copy:  $rel$replace"
        try {
            # -ErrorAction Stop: copy/move errors (e.g. the old file is open in Plex) must reach the catch
            Copy-Item -LiteralPath $f.FullName -Destination $tmp -Force -ErrorAction Stop
            Move-Item -LiteralPath $tmp -Destination $out -Force -ErrorAction Stop
            Copy-Timestamp $f $out
            $copied++
            if ($replace) { $replaced++ }
        } catch {
            Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
            Add-Content -LiteralPath $log -Value "copy failed: $($f.FullName)"
            Write-Host "  FAILED" -ForegroundColor Red
            $failed++
        }
        continue
    }

    # Has APAC or Dolby Vision: remux into the same container type as the original
    Write-Host "[$i/$total] remux: $rel$replace"
    $fmt = if ($f.Extension -ieq ".mp4") { "mp4" } else { "mov" }

    & ffmpeg -hide_banner -loglevel error -nostdin -y `
        -i $f.FullName `
        -map 0:v:0 -map "0:a:0?" `
        -c copy -tag:v hvc1 `
        -map_metadata 0 -movflags "+faststart+use_metadata_tags" `
        -f $fmt $tmp

    $ok = $LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $tmp)
    if ($ok) {
        try {
            # Timestamps after the move: Windows gives a replacing file the old file's creation time
            Move-Item -LiteralPath $tmp -Destination $out -Force -ErrorAction Stop
            Copy-Timestamp $f $out
        } catch {
            $ok = $false
        }
    }
    if ($ok) {
        $remuxed++
        if ($replace) { $replaced++ }
    } else {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        Add-Content -LiteralPath $log -Value "remux failed: $($f.FullName)"
        Write-Host "  FAILED" -ForegroundColor Red
        $failed++
    }
}

Write-Host ""
Write-Host "Done. Remuxed: $remuxed, copied as is: $copied, of these replacing older copies: $replaced, already existed: $skipped (of them renamed: $renamed), failed: $failed" -ForegroundColor Green
if ($failed -gt 0) {
    Write-Host "Failed files are listed in: $log" -ForegroundColor Yellow
    exit 1
}
