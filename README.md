# remux-iphone-videos

A PowerShell script that makes iPhone videos play properly in **Plex**.

Recent iPhones record video with an extra **APAC** (Apple Positional Audio Codec, spatial audio) track next to the normal AAC stereo track. Plex does not understand APAC: on clients such as Plex for iOS/iPadOS this can cause very long start-up delays, video not showing at all, audio appearing only after minutes, or downloads failing with *"transcoding failed"*, even though Plex reports Direct Play for both video and audio.

This script removes the APAC track by **remuxing** the file. Video and AAC audio are copied as is, with **no re-encoding**, so quality stays bit-identical and processing is limited only by disk speed.

## What it does

- Scans the source folder (including subfolders) for `.mov` and `.mp4` files.
- Checks every file with `ffprobe`:
  - files **with APAC** are remuxed into the same container (`.MOV` → `.MOV`, `.mp4` → `.mp4`), keeping the first video track and the first audio track (AAC stereo);
  - files **without APAC** are copied as is.
- Keeps file names and extensions exactly as in the source, including letter case, and mirrors the folder structure in the destination.
- Preserves the iPhone metadata (capture date, location, etc.) and the original file timestamps.
- Adds the `hvc1` HEVC tag preferred by Apple devices and moves the index to the start of the file (`faststart`) so network playback starts immediately.
- **Never modifies the originals.**

## Safe to run any number of times

- Files that already exist in the destination are skipped; only missing files are processed.
- Every file is written to a temporary `.part` file first and renamed only after it completes successfully. Unfinished `.part` files from an interrupted run are removed at the start of the next run, so you can stop the script at any time (even by turning off the computer) and simply run it again.
- The error log `remux-errors.log` in the destination folder is recreated on each run and lists only files that failed in the latest run.

Note that the script only looks at file names: if you replace a source file with a different file of the same name, delete the old copy in the destination to have it processed again. The script never deletes anything from the destination.

## Requirements

- Windows with PowerShell 5.1 or newer
- [FFmpeg](https://ffmpeg.org/) (`ffmpeg` and `ffprobe` in `PATH`). A recent build is needed to recognize the APAC track. On Windows the easiest way is:

  ```powershell
  winget install Gyan.FFmpeg
  ```

  Close and reopen PowerShell after installing.

## Usage

```powershell
powershell -ExecutionPolicy Bypass -File .\remux-iphone-videos.ps1 -Source "D:\Videos\iPhone" -Dest "D:\Videos\iPhone (Plex)"
```

| Parameter | Description |
|-----------|-------------|
| `-Source` | Folder with the original videos |
| `-Dest`   | Folder for the processed copies (created if missing) |

The destination can be a network share, e.g. a NAS used by Plex:

```powershell
powershell -ExecutionPolicy Bypass -File .\remux-iphone-videos.ps1 -Source "D:\Videos\iPhone" -Dest "\\NAS\Videos\iPhone"
```

At the end the script prints a summary: how many files were remuxed, copied, skipped and failed.

## Before you start

- The destination needs about as much free space as the source videos take.
- Disable sleep in Windows power settings for long runs. Running background processes do not prevent Windows from going to sleep.

## Notes

- Keep the originals: they contain the spatial audio track and the Dolby Vision metadata. The processed copies are meant for Plex and can always be recreated with this script.
- After remuxing, Plex shows the video as **4K HLG** instead of *DoVi/HLG*: the Dolby Vision layer is dropped, but the HLG HDR stays, and HDR playback works the same on Apple devices.
- Plex may still label the audio as *"Unknown (AAC Stereo)"*. This is only how Plex names the iPhone audio track; it plays as Direct Play.
