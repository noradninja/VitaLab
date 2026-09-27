[CmdletBinding()]
param(
    [string]$Address = '192.168.2.222',
    [ValidateRange(1, 65535)]
    [int]$Port = 19600,
    [ValidatePattern('^[A-Z0-9]{9}$')]
    [string]$TitleId = 'VLAB00210',
    [ValidateRange(1, 60)]
    [int]$VisibleSeconds = 5,
    [ValidateRange(100, 60000)]
    [int]$TimeoutMs = 5000,
    [string]$ElfPath = (Join-Path $PSScriptRoot '..\build-vita-plugin\vitalab'),
    [string]$RunRoot = (Join-Path $PSScriptRoot '..\runs')
)

$ErrorActionPreference = 'Stop'

function Invoke-AgentLine {
    param([string]$Command)

    $client = [System.Net.Sockets.TcpClient]::new()
    $reader = $null
    $writer = $null
    try {
        $connect = $client.ConnectAsync($Address, $Port)
        if (-not $connect.Wait($TimeoutMs)) {
            throw "Timed out connecting to ${Address}:$Port."
        }
        if ($connect.IsFaulted) {
            throw $connect.Exception.GetBaseException()
        }
        $stream = $client.GetStream()
        $reader = [System.IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
        $writer = [System.IO.StreamWriter]::new($stream, [Text.Encoding]::ASCII, 1024, $true)
        $writer.NewLine = "`n"
        $writer.WriteLine($Command)
        $writer.Flush()
        $read = $reader.ReadLineAsync()
        if (-not $read.Wait($TimeoutMs)) {
            throw "Timed out waiting for '$Command'."
        }
        if ($null -eq $read.Result) {
            throw "The agent closed the connection after '$Command'."
        }
        return $read.Result
    } finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $reader) { $reader.Dispose() }
        $client.Dispose()
    }
}

$resolvedElf = (Resolve-Path -LiteralPath $ElfPath).Path
$elfHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedElf).Hash.ToLowerInvariant()
$startedAt = [DateTime]::UtcNow
$responses = [ordered]@{}
$result = 'FAIL'
$failure = $null

try {
    $responses.INFO_BEFORE = Invoke-AgentLine 'INFO'
    if ($responses.INFO_BEFORE -notmatch '^VITALAB/1 INFO version=([^ ]+) platform=psvita build=([^ ]+) commit=([^ ]+)$') {
        throw "Unexpected initial INFO response: $($responses.INFO_BEFORE)"
    }
    $agentVersion = $Matches[1]
    $buildId = $Matches[2]
    $gitCommit = $Matches[3]

    $responses.LAUNCH = Invoke-AgentLine "LAUNCH $TitleId"
    if ($responses.LAUNCH -ne "OK LAUNCH $TitleId") {
        throw "Launch failed: $($responses.LAUNCH)"
    }

    Start-Sleep -Seconds $VisibleSeconds
    $responses.PING_FOREGROUND = Invoke-AgentLine 'PING'
    if ($responses.PING_FOREGROUND -ne 'PONG') {
        throw "Foreground PING failed: $($responses.PING_FOREGROUND)"
    }

    $responses.STOP = Invoke-AgentLine "STOP $TitleId"
    if ($responses.STOP -ne "OK STOP $TitleId") {
        throw "Stop failed: $($responses.STOP)"
    }

    Start-Sleep -Seconds 2
    $responses.INFO_AFTER = Invoke-AgentLine 'INFO'
    if ($responses.INFO_AFTER -ne $responses.INFO_BEFORE) {
        throw 'Agent identity changed after application control.'
    }
    $result = 'PASS'
} catch {
    $failure = $_.Exception.Message
}

$finishedAt = [DateTime]::UtcNow
$safeBuildId = if ($null -ne $buildId) {
    $buildId -replace '[^A-Za-z0-9._-]', '_'
} else {
    'unknown-build'
}
$timestamp = $startedAt.ToString('yyyyMMddTHHmmssfffZ')
$runDirectory = Join-Path $RunRoot "$timestamp-application-control-$safeBuildId"
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
Copy-Item -LiteralPath $resolvedElf -Destination (Join-Path $runDirectory 'vitalab-agent.elf')

$manifest = [ordered]@{
    schemaVersion = 1
    test = 'application-control'
    result = $result
    startedAtUtc = $startedAt.ToString('o')
    finishedAtUtc = $finishedAt.ToString('o')
    target = [ordered]@{ address = $Address; port = $Port; platform = 'psvita' }
    controlledTitleId = $TitleId
    visibleSeconds = $VisibleSeconds
    identity = [ordered]@{
        agentVersion = $agentVersion
        buildId = $buildId
        gitCommit = $gitCommit
    }
    elf = [ordered]@{
        file = 'vitalab-agent.elf'
        sha256 = $elfHash
        sourcePath = $resolvedElf
    }
    responses = $responses
    failure = $failure
}
$manifest | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $runDirectory 'manifest.json') -Encoding utf8

[pscustomobject]@{
    Result = $result
    Endpoint = "${Address}:$Port"
    TitleId = $TitleId
    Launch = $responses.LAUNCH
    ForegroundPing = $responses.PING_FOREGROUND
    Stop = $responses.STOP
    BuildId = $buildId
    ElfSha256 = $elfHash
    RunDirectory = (Resolve-Path -LiteralPath $runDirectory).Path
}

if ($result -ne 'PASS') {
    throw "VitaLab application-control test failed: $failure"
}
