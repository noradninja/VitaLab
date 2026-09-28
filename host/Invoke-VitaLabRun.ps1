[CmdletBinding()]
param(
    [string]$Address = '192.168.2.222',
    [ValidateRange(1, 65535)]
    [int]$Port = 19600,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Z0-9]{9}$')]
    [string]$TitleId,
    [ValidateRange(5, 1800)]
    [int]$ExitTimeoutSeconds = 300,
    [string]$ElfPath = (Join-Path $PSScriptRoot '..\build-vita-plugin\vitalab'),
    [string]$RunRoot = (Join-Path $PSScriptRoot '..\runs')
)

$ErrorActionPreference = 'Stop'
$startedAt = [DateTime]::UtcNow
$timestamp = $startedAt.ToString('yyyyMMddTHHmmssfffZ')
$resolvedElf = (Resolve-Path -LiteralPath $ElfPath).Path
$elfHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedElf).Hash.ToLowerInvariant()
$hostGitCommit = (& git -C (Join-Path $PSScriptRoot '..') rev-parse HEAD).Trim()
$components = [ordered]@{}
$failures = [ordered]@{}
$baseline = $null
$lifecycle = $null
$artifacts = $null

function Invoke-Component {
    param([string]$Name, [scriptblock]$Action)
    Write-Host "Starting VitaLab component: $Name"
    try {
        $value = & $Action
        $script:components[$Name] = [ordered]@{
            result = $value.Result
            runDirectory = $value.RunDirectory
            summary = $value
        }
        return $value
    } catch {
        $script:failures[$Name] = $_.Exception.Message
        $script:components[$Name] = [ordered]@{
            result = 'FAIL'
            runDirectory = $null
            error = $_.Exception.Message
        }
        return $null
    }
}

$baseline = Invoke-Component -Name 'baseline' -Action {
    & (Join-Path $PSScriptRoot 'Test-VitaLabAgent.ps1') `
        -Address $Address -Port $Port -ElfPath $resolvedElf -RunRoot $RunRoot
}

if ($null -ne $baseline -and $baseline.Result -eq 'PASS') {
    $lifecycle = Invoke-Component -Name 'applicationLifecycle' -Action {
        & (Join-Path $PSScriptRoot 'Test-VitaLabApplicationLifecycle.ps1') `
            -Address $Address -Port $Port -TitleId $TitleId `
            -ExitTimeoutSeconds $ExitTimeoutSeconds -ElfPath $resolvedElf `
            -RunRoot $RunRoot
    }
} else {
    $failures.applicationLifecycle = 'Skipped because the baseline agent check failed.'
    $components.applicationLifecycle = [ordered]@{
        result = 'SKIPPED'
        runDirectory = $null
        error = $failures.applicationLifecycle
    }
}

# Artifact collection is intentionally attempted after both PASS and FAIL runs.
$artifacts = Invoke-Component -Name 'artifactRetrieval' -Action {
    & (Join-Path $PSScriptRoot 'Test-VitaLabArtifactRetrieval.ps1') `
        -Address $Address -Port $Port -ElfPath $resolvedElf -RunRoot $RunRoot
}

$finishedAt = [DateTime]::UtcNow
$result = if ($failures.Count -eq 0 -and
    $null -ne $baseline -and $baseline.Result -eq 'PASS' -and
    $null -ne $lifecycle -and $lifecycle.Result -eq 'PASS' -and
    $null -ne $artifacts -and $artifacts.Result -eq 'PASS') { 'PASS' } else { 'FAIL' }
$buildId = if ($null -ne $baseline) { $baseline.BuildId } else { 'unknown-build' }
$safeBuildId = $buildId -replace '[^A-Za-z0-9._-]', '_'
$runDirectory = Join-Path $RunRoot "$timestamp-orchestrated-$safeBuildId"
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
Copy-Item -LiteralPath $resolvedElf -Destination (Join-Path $runDirectory 'vitalab-agent.elf')

$manifest = [ordered]@{
    schemaVersion = 1
    test = 'orchestrated-hardware-run'
    result = $result
    startedAtUtc = $startedAt.ToString('o')
    finishedAtUtc = $finishedAt.ToString('o')
    hostGitCommit = $hostGitCommit
    target = [ordered]@{ address = $Address; port = $Port; platform = 'psvita'; titleId = $TitleId }
    agent = [ordered]@{
        buildId = if ($null -ne $baseline) { $baseline.BuildId } else { $null }
        gitCommit = if ($null -ne $baseline) { $baseline.GitCommit } else { $null }
    }
    elf = [ordered]@{ file = 'vitalab-agent.elf'; sha256 = $elfHash; sourcePath = $resolvedElf }
    components = $components
    failures = $failures
}
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $runDirectory 'manifest.json') -Encoding utf8

[pscustomobject]@{
    Result = $result
    Endpoint = "${Address}:$Port"
    TitleId = $TitleId
    BuildId = $buildId
    Baseline = $components.baseline.result
    ApplicationLifecycle = $components.applicationLifecycle.result
    ArtifactRetrieval = $components.artifactRetrieval.result
    ElfSha256 = $elfHash
    RunDirectory = (Resolve-Path -LiteralPath $runDirectory).Path
}

if ($result -ne 'PASS') {
    throw "VitaLab orchestrated run failed. Evidence: $((Resolve-Path -LiteralPath $runDirectory).Path)"
}
