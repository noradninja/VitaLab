[CmdletBinding()]
param(
    [string]$Address = '192.168.2.222',
    [ValidateRange(1, 65535)]
    [int]$Port = 19600,
    [ValidateRange(100, 60000)]
    [int]$TimeoutMs = 30000,
    [switch]$RequireDump,
    [string]$ElfPath = (Join-Path $PSScriptRoot '..\build-vita-plugin\vitalab'),
    [string]$RunRoot = (Join-Path $PSScriptRoot '..\runs')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VitaLabHostCommon.ps1')

function Open-AgentConnection {
    $client = [System.Net.Sockets.TcpClient]::new()
    $connect = $client.ConnectAsync($Address, $Port)
    if (-not $connect.Wait($TimeoutMs)) { $client.Dispose(); throw "Timed out connecting to ${Address}:$Port." }
    if ($connect.IsFaulted) { $failure = $connect.Exception.GetBaseException(); $client.Dispose(); throw $failure }
    $stream = $client.GetStream()
    $stream.ReadTimeout = $TimeoutMs
    $stream.WriteTimeout = $TimeoutMs
    [pscustomobject]@{ Client = $client; Stream = $stream }
}

function Write-AgentLine {
    param([System.IO.Stream]$Stream, [string]$Line)
    $bytes = [Text.Encoding]::ASCII.GetBytes("$Line`n")
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Read-AgentLineRaw {
    param([System.IO.Stream]$Stream)
    $bytes = [System.Collections.Generic.List[byte]]::new()
    while ($bytes.Count -le 512) {
        $value = $Stream.ReadByte()
        if ($value -lt 0) { throw 'The agent closed the connection.' }
        if ($value -eq 10) {
            if ($bytes.Count -gt 0 -and $bytes[$bytes.Count - 1] -eq 13) { $bytes.RemoveAt($bytes.Count - 1) }
            return [Text.Encoding]::ASCII.GetString($bytes.ToArray())
        }
        $bytes.Add([byte]$value)
    }
    throw 'The agent returned an overlong response line.'
}

function Invoke-LineCommand {
    param([string]$Command)
    $connection = Open-AgentConnection
    try { Write-AgentLine $connection.Stream $Command; Read-AgentLineRaw $connection.Stream }
    finally { $connection.Stream.Dispose(); $connection.Client.Dispose() }
}

function Receive-Artifact {
    param([string]$Command, [string]$Verb, [string]$Name)
    $connection = Open-AgentConnection
    try {
        Write-AgentLine $connection.Stream $Command
        $header = Read-AgentLineRaw $connection.Stream
        $pattern = '^OK ' + [regex]::Escape($Verb) + ' ' + [regex]::Escape($Name) + ' ([0-9]+)$'
        if ($header -notmatch $pattern) { throw "Unexpected artifact response: $header" }
        $length = [int]$Matches[1]
        $data = [byte[]]::new($length)
        $offset = 0
        while ($offset -lt $length) {
            $read = $connection.Stream.Read($data, $offset, $length - $offset)
            if ($read -le 0) { throw "The agent closed after $offset of $length artifact bytes." }
            $offset += $read
        }
        [pscustomobject]@{ Header = $header; Data = $data }
    } finally { $connection.Stream.Dispose(); $connection.Client.Dispose() }
}

function Get-DumpList {
    $connection = Open-AgentConnection
    try {
        Write-AgentLine $connection.Stream 'LIST DUMPS'
        $header = Read-AgentLineRaw $connection.Stream
        if ($header -ne 'OK DUMPS') { throw "Unexpected dump-list response: $header" }
        $items = [System.Collections.Generic.List[object]]::new()
        for (;;) {
            $line = Read-AgentLineRaw $connection.Stream
            if ($line -eq 'END DUMPS') { break }
            if ($line -notmatch '^DUMP (psp2core-[A-Za-z0-9._-]+\.psp2dmp) ([0-9]+)$') {
                throw "Unexpected dump-list entry: $line"
            }
            $items.Add([pscustomobject]@{ Name = $Matches[1]; Size = [int64]$Matches[2] })
        }
        return $items
    } finally { $connection.Stream.Dispose(); $connection.Client.Dispose() }
}

$resolvedElf = (Resolve-Path -LiteralPath $ElfPath).Path
$elfHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedElf).Hash.ToLowerInvariant()
$expectedIdentity = Get-VitaLabElfIdentity -ElfPath $resolvedElf
$startedAt = [DateTime]::UtcNow
$responses = [ordered]@{}
$agentVersion = $null; $buildId = $null; $gitCommit = $null
$logData = $null; $logHash = $null; $dumpData = $null; $dumpHash = $null; $selectedDump = $null
$dumps = @(); $result = 'FAIL'; $failure = $null

try {
    $responses.INVALID_LOG = Invoke-LineCommand 'GET LOG ../agent.log'
    if ($responses.INVALID_LOG -ne 'ERR INVALID_ARTIFACT') { throw "Invalid log request was not rejected: $($responses.INVALID_LOG)" }
    $responses.INVALID_DUMP = Invoke-LineCommand 'GET DUMP ../escape.psp2dmp'
    if ($responses.INVALID_DUMP -ne 'ERR INVALID_ARTIFACT') { throw "Invalid dump request was not rejected: $($responses.INVALID_DUMP)" }

    $responses.INFO_BEFORE = Invoke-LineCommand 'INFO'
    if ($responses.INFO_BEFORE -notmatch '^VITALAB/1 INFO version=([^ ]+) platform=psvita build=([^ ]+) commit=([^ ]+)$') { throw "Unexpected INFO response: $($responses.INFO_BEFORE)" }
    $agentVersion = $Matches[1]; $buildId = $Matches[2]; $gitCommit = $Matches[3]
    Assert-VitaLabIdentityMatchesElf -Expected $expectedIdentity -AgentVersion $agentVersion -BuildId $buildId -GitCommit $gitCommit

    $log = Receive-Artifact -Command 'GET LOG agent.log' -Verb 'LOG' -Name 'agent.log'
    $responses.LOG = $log.Header
    $logData = $log.Data
    $logHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($logData)).ToLowerInvariant()

    $dumps = @(Get-DumpList)
    if ($dumps.Count -gt 0) {
        $selectedDump = $dumps | Sort-Object Size | Select-Object -First 1
        $dump = Receive-Artifact -Command "GET DUMP $($selectedDump.Name)" -Verb 'DUMP' -Name $selectedDump.Name
        $responses.DUMP = $dump.Header
        $dumpData = $dump.Data
        $dumpHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($dumpData)).ToLowerInvariant()
        if ($dumpData.Length -ne $selectedDump.Size) { throw 'Retrieved dump size did not match its listing.' }
    } elseif ($RequireDump) {
        throw 'No psp2core-*.psp2dmp artifacts were found under ux0:data.'
    }

    $responses.PING_AFTER = Invoke-LineCommand 'PING'
    $responses.INFO_AFTER = Invoke-LineCommand 'INFO'
    if ($responses.PING_AFTER -ne 'PONG' -or $responses.INFO_AFTER -ne $responses.INFO_BEFORE) { throw 'Agent health or identity changed during artifact retrieval.' }
    $result = 'PASS'
} catch { $failure = $_.Exception.Message }

$finishedAt = [DateTime]::UtcNow
$safeBuildId = if ($null -ne $buildId) { $buildId -replace '[^A-Za-z0-9._-]', '_' } else { 'unknown-build' }
$timestamp = $startedAt.ToString('yyyyMMddTHHmmssfffZ')
$runDirectory = Join-Path $RunRoot "$timestamp-artifact-retrieval-$safeBuildId"
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
Copy-Item -LiteralPath $resolvedElf -Destination (Join-Path $runDirectory 'vitalab-agent.elf')
if ($null -ne $logData) { [IO.File]::WriteAllBytes((Join-Path $runDirectory 'agent.log'), $logData) }
if ($null -ne $dumpData) { [IO.File]::WriteAllBytes((Join-Path $runDirectory $selectedDump.Name), $dumpData) }

$manifest = [ordered]@{
    schemaVersion = 1; test = 'artifact-retrieval'; result = $result
    startedAtUtc = $startedAt.ToString('o'); finishedAtUtc = $finishedAt.ToString('o')
    target = [ordered]@{ address = $Address; port = $Port; platform = 'psvita' }
    identity = [ordered]@{ agentVersion = $agentVersion; buildId = $buildId; gitCommit = $gitCommit }
    elf = [ordered]@{ file = 'vitalab-agent.elf'; sha256 = $elfHash; sourcePath = $resolvedElf }
    log = [ordered]@{ file = 'agent.log'; bytes = if ($null -ne $logData) { $logData.Length } else { $null }; sha256 = $logHash }
    dumps = $dumps
    selectedDump = if ($null -ne $selectedDump) { [ordered]@{ file = $selectedDump.Name; bytes = $selectedDump.Size; sha256 = $dumpHash } } else { $null }
    responses = $responses; failure = $failure
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDirectory 'manifest.json') -Encoding utf8

[pscustomobject]@{
    Result = $result; Endpoint = "${Address}:$Port"; LogBytes = if ($null -ne $logData) { $logData.Length } else { $null }
    LogSha256 = $logHash; DumpsFound = $dumps.Count; DumpRetrieved = if ($null -ne $selectedDump) { $selectedDump.Name } else { $null }
    DumpSha256 = $dumpHash; BuildId = $buildId; ElfSha256 = $elfHash
    RunDirectory = (Resolve-Path -LiteralPath $runDirectory).Path
}
if ($result -ne 'PASS') { throw "VitaLab artifact-retrieval test failed: $failure" }
