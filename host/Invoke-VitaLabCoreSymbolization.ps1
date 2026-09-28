[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DumpPath,
    [Parameter(Mandatory = $true)]
    [string]$TargetElfPath,
    [string]$ModuleName,
    [string]$VitaSdkPath = 'E:\dev\VitaSDK',
    [ValidateRange(1, 65536)]
    [int]$MaxStackWords = 1024,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$resolvedDump = (Resolve-Path -LiteralPath $DumpPath).Path
$resolvedElf = (Resolve-Path -LiteralPath $TargetElfPath).Path
$resolvedVitaSdk = (Resolve-Path -LiteralPath $VitaSdkPath).Path
$addr2Line = Join-Path $resolvedVitaSdk 'bin\arm-vita-eabi-addr2line.exe'
if (-not (Test-Path -LiteralPath $addr2Line -PathType Leaf)) {
    throw "VitaSDK addr2line was not found at $addr2Line."
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path (Split-Path -Parent $resolvedDump) 'symbolized'
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$textPath = Join-Path $output 'symbolized.txt'
$jsonPath = Join-Path $output 'symbolized.json'
$project = Join-Path $PSScriptRoot '..\tools\VitaLab.Symbolizer\VitaLab.Symbolizer.csproj'

$arguments = @(
    'run', '--configuration', 'Release', '--project', $project, '--',
    '--dump', $resolvedDump,
    '--elf', $resolvedElf,
    '--addr2line', $addr2Line,
    '--text', $textPath,
    '--json', $jsonPath,
    '--max-stack-words', $MaxStackWords
)
if (-not [string]::IsNullOrWhiteSpace($ModuleName)) {
    $arguments += @('--module', $ModuleName)
}

$toolOutput = @(& dotnet @arguments 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Local core-dump symbolization failed with exit code ${LASTEXITCODE}: $($toolOutput -join [Environment]::NewLine)"
}
$toolOutput | ForEach-Object { Write-Verbose $_ }

$analysis = Get-Content -Raw -LiteralPath $jsonPath | ConvertFrom-Json
[pscustomobject]@{
    Result = 'PASS'
    DumpPath = $resolvedDump
    DumpSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedDump).Hash.ToLowerInvariant()
    TargetElfPath = $resolvedElf
    TargetElfSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedElf).Hash.ToLowerInvariant()
    Thread = $analysis.Thread.Name
    ProgramCounter = ('0x{0:x8}' -f [uint32]$analysis.ProgramCounter.RuntimeAddress)
    Function = $analysis.ProgramCounter.Function
    Location = $analysis.ProgramCounter.Location
    StackCandidates = $analysis.StackCandidates.Count
    TextPath = (Resolve-Path -LiteralPath $textPath).Path
    JsonPath = (Resolve-Path -LiteralPath $jsonPath).Path
}
