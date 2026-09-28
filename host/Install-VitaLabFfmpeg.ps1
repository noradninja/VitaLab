[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..\third_party\ffmpeg\manifest.json'),
    [string]$CacheRoot = (Join-Path $PSScriptRoot '..\third_party\ffmpeg\cache'),
    [string]$PayloadRoot = (Join-Path $PSScriptRoot '..\third_party\ffmpeg\payload')
)

$ErrorActionPreference = 'Stop'
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json

function Get-LowerSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-VerifiedArchive {
    param(
        [Parameter(Mandatory = $true)]$Descriptor,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )

    New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null
    $path = Join-Path $DestinationRoot $Descriptor.archiveName
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "Downloading $($Descriptor.archiveName)..."
        Invoke-WebRequest -Uri $Descriptor.url -OutFile $path
    }

    $actual = Get-LowerSha256 -Path $path
    if ($actual -ne $Descriptor.sha256) {
        throw "SHA-256 mismatch for $path. Expected $($Descriptor.sha256), got $actual."
    }
    $path
}

$binaryArchive = Get-VerifiedArchive -Descriptor $manifest.binary -DestinationRoot $CacheRoot
$sourceArchive = Get-VerifiedArchive -Descriptor $manifest.source -DestinationRoot $CacheRoot
$payloadDirectory = Join-Path $PayloadRoot $manifest.binary.payloadDirectory

if (-not (Test-Path -LiteralPath $payloadDirectory)) {
    New-Item -ItemType Directory -Force -Path $PayloadRoot | Out-Null
    Expand-Archive -LiteralPath $binaryArchive -DestinationPath $PayloadRoot
}

foreach ($entry in $manifest.binary.files.psobject.Properties) {
    $filePath = Join-Path $payloadDirectory ($entry.Name -replace '/', '\')
    if (-not (Test-Path -LiteralPath $filePath)) {
        throw "Pinned FFmpeg payload file is missing: $filePath"
    }
    $actual = Get-LowerSha256 -Path $filePath
    if ($actual -ne $entry.Value) {
        throw "SHA-256 mismatch for $filePath. Expected $($entry.Value), got $actual."
    }
}

$licensePath = Join-Path $payloadDirectory 'LICENSE.txt'
if (-not (Test-Path -LiteralPath $licensePath)) {
    throw "The FFmpeg payload does not contain LICENSE.txt."
}

[pscustomobject]@{
    Result = 'PASS'
    Version = $manifest.version
    PayloadDirectory = (Resolve-Path -LiteralPath $payloadDirectory).Path
    BinaryArchive = (Resolve-Path -LiteralPath $binaryArchive).Path
    SourceArchive = (Resolve-Path -LiteralPath $sourceArchive).Path
    License = $manifest.license
}
