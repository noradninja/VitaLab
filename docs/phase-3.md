# Phase 3: FFmpeg capture

VitaLab captures PlayStation TV HDMI evidence independently from the Vita-side
agent. The Windows host opens the capture card through FFmpeg's DirectShow input
and records full-frame video with the card's HDMI audio endpoint.

OBS is not part of the capture path. A pinned FFmpeg and ffprobe payload is
verified before use so a future installer can provide the same runtime without
requiring a separate multimedia application.

## Runtime setup

```powershell
.\host\Install-VitaLabFfmpeg.ps1
```

This downloads and verifies both the LGPL Windows runtime and its exact matching
source archive. The cached payload is intentionally excluded from Git. Release
packaging must include the payload's `LICENSE.txt`, `third_party/ffmpeg/NOTICE.md`,
the manifest, and the matching source archive.

The host rejects a runtime if its archive or executable hash differs from the
manifest, if its identity does not match the pinned source commit, if it was
configured with GPL or nonfree components, or if required capture and encoding
capabilities are unavailable.

## Discovery gate

```powershell
.\host\Test-VitaLabCaptureDiscovery.ps1
```

The default endpoints are `Game Capture HD60 Pro` and the card's synchronized
`Game Capture HD60 Pro Audio` DirectShow pin. The similarly named Windows
`Microphone (Game Capture HD60 Pro)` endpoint enumerates but cannot be opened in
the same DirectShow graph as this card's video endpoint. Discovery archives only friendly names
and SHA-256 hashes of DirectShow alternative identifiers; raw PnP paths are not
written to run evidence.

The first hardware discovery gate passed on 2026-09-28 with 18 video modes and
22 audio modes reported by the selected HD60 Pro endpoints. Evidence is under
`runs/20260928T144118045Z-capture-discovery`. The verified FFmpeg executable
SHA-256 was `4ca15a262e8ea592d7d27f9ef78cd4ef5d2be1f7482fc4d38570749421e426eb`;
ffprobe was `40897d70483660d5af3b1652e9f885994cbd1f3cb5fd7b19087712e9d4309c75`.

## Recording gate

```powershell
.\host\Test-VitaLabCaptureRecording.ps1
```

The recorder opens video and audio in one DirectShow graph, preserves the full
negotiated frame, and writes Matroska. It selects Media Foundation H.264 only
after a live encoder test and otherwise falls back to FFmpeg's native MPEG-4
encoder. HDMI audio is encoded as stereo 48 kHz AAC. FFmpeg progress is archived
as JSON Lines, and ffprobe plus a full decode validate the finished recording.

The first full recording gate passed on 2026-09-28. It preserved 60.591 seconds
of 1280x720 60 fps H.264 video and stereo 48 kHz AAC audio, stopped gracefully,
and passed a complete decode. The Matroska SHA-256 was
`d9f9ef0e90bfc9fd61e36da5d07e0556a1550ce2695c54e2c26fd7c8efa95b4a`.
Evidence is under `runs/20260928T144746357Z-capture-recording`.

The explicit fallback gate also passed with a 5.321-second MPEG-4/AAC recording
and full decode under `runs/20260928T144941144Z-capture-recording`.
