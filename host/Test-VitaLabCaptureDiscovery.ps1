[CmdletBinding()]
param(
    [string]$VideoDevice = 'Game Capture HD60 Pro',
    [string]$AudioDevice = 'Game Capture HD60 Pro Audio',
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..\third_party\ffmpeg\manifest.json'),
    [string]$PayloadRoot = (Join-Path $PSScriptRoot '..\third_party\ffmpeg\payload'),
    [string]$RunRoot = (Join-Path $PSScriptRoot '..\runs')
)

$ErrorActionPreference = 'Stop'
$startedAt = [DateTime]::UtcNow
$timestamp = $startedAt.ToString('yyyyMMddTHHmmssfffZ')
$runDirectory = Join-Path $RunRoot "$timestamp-capture-discovery"
$project = Join-Path $PSScriptRoot '..\tools\VitaLab.Capture\VitaLab.Capture.csproj'
$preflightPath = Join-Path $runDirectory 'ffmpeg-preflight.json'
$discoveryPath = Join-Path $runDirectory 'capture-discovery.json'

New-Item -ItemType Directory -Force -Path $runDirectory | Out-Null

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
    'discover', '--manifest', $ManifestPath, '--payload-root', $PayloadRoot,
    '--video-device', $VideoDevice, '--audio-device', $AudioDevice,
    '--json', $discoveryPath
)

$preflight = Get-Content -LiteralPath $preflightPath -Raw | ConvertFrom-Json
$discovery = Get-Content -LiteralPath $discoveryPath -Raw | ConvertFrom-Json
$finishedAt = [DateTime]::UtcNow
$manifest = [ordered]@{
    schemaVersion = 1
    test = 'capture-discovery'
    result = 'PASS'
    startedAtUtc = $startedAt.ToString('o')
    finishedAtUtc = $finishedAt.ToString('o')
    videoDevice = $VideoDevice
    audioDevice = $AudioDevice
    ffmpeg = [ordered]@{
        version = $preflight.version
        sourceCommit = $preflight.sourceCommit
        ffmpegSha256 = $preflight.ffmpegSha256
        ffprobeSha256 = $preflight.ffprobeSha256
        capabilities = $preflight.capabilities
    }
    videoOptionCount = @($discovery.videoOptions).Count
    audioOptionCount = @($discovery.audioOptions).Count
    evidence = [ordered]@{
        preflight = 'ffmpeg-preflight.json'
        discovery = 'capture-discovery.json'
    }
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDirectory 'manifest.json') -Encoding utf8

[pscustomobject]@{
    Result = 'PASS'
    VideoDevice = $VideoDevice
    AudioDevice = $AudioDevice
    VideoOptions = @($discovery.videoOptions).Count
    AudioOptions = @($discovery.audioOptions).Count
    FfmpegVersion = $preflight.version
    RunDirectory = (Resolve-Path -LiteralPath $runDirectory).Path
}
