# Satsuma

The zero-click offline file converter for macOS. Hold **Shift** while dragging files in Finder to convert them; add **Option** to open advanced tools. Everything runs locally on your Mac — nothing is uploaded, and the original file is never modified.

Satsuma is an open-source reimplementation of the Tangerine workflow: 188 conversion options across images, video, audio, documents, subtitles and archives, and 25 advanced file tools.

## How it works

1. Start dragging one or more files in Finder (or any app).
2. Hold **Shift**. A radial menu appears around the cursor with the formats the selection can be converted to.
3. Move over a format and release to convert. Copies are written next to the originals (or to the folder chosen in Settings).
4. Hold **Shift + Option** instead to switch the radial menu to advanced tools (Compress, Crop, Trim, Merge PDFs, …). Releasing on a tool opens its window with a live preview.

Keyboard: while the radial menu is open, press **Option** to toggle between formats and tools, arrow keys to choose, **Return** to apply, **Escape** to cancel.

Satsuma lives in the menu bar (no Dock icon). The status item shows job progress and opens Settings.

## Conversions

| Source | Targets |
| --- | --- |
| JPG, PNG | PNG/JPG, WebP, HEIC, TIFF, AVIF, BMP, PDF, DOCX |
| WebP, HEIC, TIFF, SVG, AVIF, BMP | JPG, PNG, WebP, HEIC, TIFF, AVIF, BMP, PDF |
| MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, WMA | every other audio format |
| MP4, MOV, MKV, WebM, AVI, WMV | every other video format, GIF, MP3 |
| GIF | MP4, MOV, MKV, WebM, AVI, WMV |
| PDF | DOCX, JPG, PNG (all pages, 300 DPI), TXT |
| TXT | PDF, JPG, PNG, SRT, VTT |
| SRT, VTT | VTT/SRT, TXT |
| ZIP, TAR, GZIP, RAR | ZIP, TAR, GZIP (RAR can be read, not written) |

Native frameworks are used first: ImageIO/Core Graphics for images, AVFoundation for audio and video, PDFKit/Core Text for documents, Foundation for archives. `ffmpeg` is used only for formats Apple's frameworks cannot encode or decode (WebM/VP9, MKV, AVI, WMV, OGG, Opus, FLAC output, WMA, MP3 encoding, AVIF on macOS 13, animated GIF export). `unar`/`bsdtar` extracts RAR.

## Advanced tools

| Scope | Tools |
| --- | --- |
| Any file | Compress (Balanced/Strong, target size, resize), Edit metadata (view, edit, strip sensitive or all fields) |
| Images | Edit photos, Add a background, Crop, Redact, Resize, Rotate, Create a PDF, Make a collage |
| Video | Trim, Split, Crop, Change speed, Join, Save frames, Redact |
| Audio | Trim, Normalize volume, Convert channels, Bleep, Create an audio visualizer |
| PDF | Merge, Organize pages, Split |

## Requirements

- Apple silicon Mac running macOS 13 or later.
- [Brisk](https://github.com/plyght/brisk) and the Xcode command-line tools (`swiftc`) to build.
- Optional: `ffmpeg` for the non-native formats listed above (`wax install ffmpeg`), `unar` for RAR extraction (`wax install unar`). Satsuma looks in `PATH`, `/opt/homebrew/bin` and `/usr/local/bin`; a custom path can be set in Settings.

## Build

```bash
brisk build            # debug .app in .build/debug/Satsuma.app
brisk run              # build and launch
brisk test             # compile and run Tests/ with the app sources
brisk archive --release
```

On first launch macOS asks for **Accessibility** access (System Settings → Privacy & Security → Accessibility). Satsuma needs it to observe Shift while a drag is in progress; it never reads keystrokes otherwise. Notifications are optional.

## Quality gates

```bash
scripts/check.sh        # format check, lint, build (type-check), tests
scripts/check.sh --fix  # apply swift-format fixes first
```

`scripts/check.sh` uses `swift-format` (Apple, ships with Xcode 16 / `wax install swift-format`), `swiftlint` (`wax install swiftlint`) when present, `brisk build` as the type-check and `brisk test` for the test suite. Missing optional linters are reported and skipped; the build and tests are mandatory.

## Verification status

The GitHub Actions workflow (`.github/workflows/ci.yml`) runs on a `macos-14` runner: `brisk build`, `brisk test` (conversion matrix, naming, subtitle, PDF-range, tool-applicability, compression and timecode logic in `Tests/SatsumaTests.swift`), then launches the app with `SATSUMA_SCREENSHOTS=<dir>` so `Sources/App/ScreenshotDriver.swift` generates sample media, opens the radial menu and all 25 tool windows, and captures them with `screencapture`. Screenshots and the release `Satsuma.app` zip are uploaded as workflow artifacts. Actual Finder Shift-drag and the Accessibility prompt cannot be exercised on a headless runner and still need a manual check on a Mac.

## Project layout

```
.brisk.toml                Brisk manifest (bundle id lol.peril.satsuma, LSUIElement)
Sources/App                App delegate, status item, settings
Sources/Formats            FileFormat enum, ConversionMatrix (188 options, output naming)
Sources/Engines            Conversion engines: image, audio, video, document, subtitle, archive, ffmpeg bridge
Sources/Operations         Tool backends: ImageOps, VideoOps, AudioOps, PDFOps, MetadataOps, Compressor
Sources/Radial             Global drag/modifier monitor and the radial menu overlay
Sources/Core               Job runner, progress HUD, notifications, shell, media probing
Sources/Tools              Tool window shell, tool registry and the 25 tool views
Tests                      Direct Swift tests run by `brisk test`
```

## Privacy

No network access, no telemetry, no analytics. Files are read from disk, processed in memory or in a temporary folder under the user's temp directory, and written back as new files next to the originals.

## License

MIT
