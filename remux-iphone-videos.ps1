# Prepare iPhone videos for Plex.
# - Files WITH an APAC (spatial audio) track: remux, keep HEVC video + AAC stereo, drop APAC.
#   No re-encoding: quality stays bit-identical.
# - Files WITHOUT APAC: copied as is.
# File names and extensions are kept exactly as in the source (.MOV stays .MOV).
# Originals are never modified.
#
# Usage (in PowerShell, from the folder where this script is saved):
#   powershell -ExecutionPolicy Bypass -File .\remux-iphone-videos.ps1
# or with your own folders:
#   powershell -ExecutionPolicy Bypass -File .\remux-iphone-videos.ps1 -Source "E:\Phone Videos" -Dest "\\NAS\Videos\iPhone"
#
# Safe to re-run: files that already exist in Dest are skipped.
# Files created by the previous version of this script with a different letter case
# (e.g. ".mov" instead of ".MOV") are renamed to match the source.

param(
    [string]$Source = "D:\Videos\iPhone",
    [string]$Dest   = "D:\Videos\iPhone (Plex)"
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

$files = Get-ChildItem -LiteralPath $srcRoot -Recurse -File -ErrorVariable scanErrors |
    Where-Object { $_.Extension -ieq ".mov" -or $_.Extension -ieq ".mp4" }

$total = $files.Count
$i = 0; $remuxed = 0; $copied = 0; $skipped = 0; $renamed = 0; $failed = 0
Write-Host "Found $total .mov/.mp4 files in $srcRoot"
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

    # Already done? (Windows paths are case-insensitive, so look up the real on-disk name)
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
        $skipped++
        continue
    }

    $tmp = "$out.part"

    $streams = & ffprobe -v error -show_entries stream=codec_name,codec_tag_string -of csv=p=0 $f.FullName
    if ($LASTEXITCODE -ne 0) {
        Add-Content -LiteralPath $log -Value "ffprobe failed: $($f.FullName)"
        Write-Host "[$i/$total] $rel  FAILED (ffprobe)" -ForegroundColor Red
        $failed++
        continue
    }

    if (-not ($streams -match 'apac')) {
        # No spatial audio: plain copy
        Write-Host "[$i/$total] copy:  $rel"
        try {
            Copy-Item -LiteralPath $f.FullName -Destination $tmp -Force
            Move-Item -LiteralPath $tmp -Destination $out
            Copy-Timestamp $f $out
            $copied++
        } catch {
            Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
            Add-Content -LiteralPath $log -Value "copy failed: $($f.FullName)"
            Write-Host "  FAILED" -ForegroundColor Red
            $failed++
        }
        continue
    }

    # Has APAC: remux into the same container type as the original
    Write-Host "[$i/$total] remux: $rel"
    $fmt = if ($f.Extension -ieq ".mp4") { "mp4" } else { "mov" }

    & ffmpeg -hide_banner -loglevel error -nostdin -y `
        -i $f.FullName `
        -map 0:v:0 -map "0:a:0?" `
        -c copy -tag:v hvc1 `
        -map_metadata 0 -movflags "+faststart+use_metadata_tags" `
        -f $fmt $tmp

    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $tmp)) {
        Move-Item -LiteralPath $tmp -Destination $out
        Copy-Timestamp $f $out
        $remuxed++
    } else {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        Add-Content -LiteralPath $log -Value "remux failed: $($f.FullName)"
        Write-Host "  FAILED" -ForegroundColor Red
        $failed++
    }
}

Write-Host ""
Write-Host "Done. Remuxed: $remuxed, copied as is: $copied, already existed: $skipped (of them renamed: $renamed), failed: $failed" -ForegroundColor Green
if ($failed -gt 0) {
    Write-Host "Failed files are listed in: $log" -ForegroundColor Yellow
    exit 1
}
