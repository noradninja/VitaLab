[CmdletBinding()]
param(
    [ValidateRange(5, 3600)]
    [int]$DurationSeconds = 60,
    [ValidateSet('auto', 'mpeg4')]
    [string]$Encoder = 'auto',
    [string]$VideoDevice = 'Game Capture HD60 Pro',
    [string]$AudioDevice = 'Game Capture HD60 Pro Audio',
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..\third_party\ffmpeg\manifest.json'),
    [string]$PayloadRoot = (Join-Path $PSScriptRoot '..\third_party\ffmpeg\payload'),
    [string]$RunRoot = (Join-Path $PSScriptRoot '..\runs')
)

$ErrorActionPreference = 'Stop'
$startedAt = [DateTime]::UtcNow
$timestamp = $startedAt.ToString('yyyyMMddTHHmmssfffZ')
$runDirectory = Join-Path $RunRoot "$timestamp-capture-recording"
$videoDirectory = Join-Path $runDirectory 'video'
$project = Join-Path $PSScriptRoot '..\tools\VitaLab.Capture\VitaLab.Capture.csproj'
$preflightPath = Join-Path $runDirectory 'ffmpeg-preflight.json'
$recordingPath = Join-Path $videoDirectory 'recording.json'
$probePath = Join-Path $videoDirectory 'probe.json'
$mediaPath = Join-Path $videoDirectory 'test.mkv'
$progressPath = Join-Path $videoDirectory 'ffmpeg-progress.jsonl'
$logPath = Join-Path $videoDirectory 'ffmpeg.log'
$readyPath = Join-Path $videoDirectory 'ready.json'

New-Item -ItemType Directory -Force -Path $videoDirectory | Out-Null

function Invoke-CaptureTool {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $output = @(& dotnet run --project $project -c Release --no-build -- @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "VitaLab.Capture failed: $($output -join [Environment]::NewLine)"
    }
}

Invoke-CaptureTool -Arguments @(
    'preflight', '--manifest', $ManifestPath, '--payload-root', $PayloadRoot,
    '--json', $preflightPath
)
Invoke-CaptureTool -Arguments @(
    'record', '--manifest', $ManifestPath, '--payload-root', $PayloadRoot,
    '--video-device', $VideoDevice, '--audio-device', $AudioDevice,
    '--output', $mediaPath, '--progress-jsonl', $progressPath,
    '--log', $logPath, '--ready-file', $readyPath,
    '--encoder', $Encoder, '--duration-seconds', $DurationSeconds,
    '--json', $recordingPath
)
Invoke-CaptureTool -Arguments @(
    'probe', '--manifest', $ManifestPath, '--payload-root', $PayloadRoot,
    '--input', $mediaPath, '--json', $probePath
)

$preflight = Get-Content -LiteralPath $preflightPath -Raw | ConvertFrom-Json
$recording = Get-Content -LiteralPath $recordingPath -Raw | ConvertFrom-Json
$probe = Get-Content -LiteralPath $probePath -Raw | ConvertFrom-Json
$videoStream = @($probe.streams | Where-Object codecType -eq 'video')[0]
$audioStream = @($probe.streams | Where-Object codecType -eq 'audio')[0]
$finishedAt = [DateTime]::UtcNow
$manifest = [ordered]@{
    schemaVersion = 1
    test = 'capture-recording'
    result = 'PASS'
    startedAtUtc = $startedAt.ToString('o')
    finishedAtUtc = $finishedAt.ToString('o')
    requestedDurationSeconds = $DurationSeconds
    ffmpeg = [ordered]@{
        version = $preflight.version
        sourceCommit = $preflight.sourceCommit
        ffmpegSha256 = $preflight.ffmpegSha256
        ffprobeSha256 = $preflight.ffprobeSha256
    }
    capture = [ordered]@{
        videoDevice = $recording.videoDevice
        audioDevice = $recording.audioDevice
        encoder = $recording.encoder
        encoderPreflight = $recording.encoderPreflight
        container = $recording.container
        arguments = $recording.ffmpegArguments
        forcedTermination = $recording.forcedTermination
        progressSampleCount = $recording.progressSampleCount
    }
    media = [ordered]@{
        file = 'video/test.mkv'
        sha256 = $probe.sha256
        bytes = $probe.bytes
        durationSeconds = $probe.durationSeconds
        video = $videoStream
        audio = $audioStream
        decodeResult = $probe.decodeResult
    }
    evidence = [ordered]@{
        preflight = 'ffmpeg-preflight.json'
        recording = 'video/recording.json'
        probe = 'video/probe.json'
        progress = 'video/ffmpeg-progress.jsonl'
        log = 'video/ffmpeg.log'
        ready = 'video/ready.json'
    }
}
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $runDirectory 'manifest.json') -Encoding utf8

[pscustomobject]@{
    Result = 'PASS'
    Video = "$($videoStream.width)x$($videoStream.height) $($videoStream.frameRate) $($videoStream.codecName)"
    Audio = "$($audioStream.sampleRate) Hz $($audioStream.channels) channel $($audioStream.codecName)"
    DurationSeconds = $probe.durationSeconds
    Encoder = $recording.encoder
    MediaSha256 = $probe.sha256
    RunDirectory = (Resolve-Path -LiteralPath $runDirectory).Path
}
