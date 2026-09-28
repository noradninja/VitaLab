[CmdletBinding()]
param(
    [string]$Address = '192.168.2.222',
    [ValidateRange(1, 65535)]
    [int]$Port = 19600,
    [ValidateRange(1, 1048576)]
    [int]$PayloadSize = 65536,
    [ValidateRange(100, 60000)]
    [int]$TimeoutMs = 10000,
    [string]$ElfPath = (Join-Path $PSScriptRoot '..\build-vita-plugin\vitalab'),
    [string]$RunRoot = (Join-Path $PSScriptRoot '..\runs')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VitaLabHostCommon.ps1')

function Open-AgentConnection {
    $client = [System.Net.Sockets.TcpClient]::new()
    $connect = $client.ConnectAsync($Address, $Port)
    if (-not $connect.Wait($TimeoutMs)) {
        $client.Dispose()
        throw "Timed out connecting to ${Address}:$Port."
    }
    if ($connect.IsFaulted) {
        $failure = $connect.Exception.GetBaseException()
        $client.Dispose()
        throw $failure
    }
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
            if ($bytes.Count -gt 0 -and $bytes[$bytes.Count - 1] -eq 13) {
                $bytes.RemoveAt($bytes.Count - 1)
            }
            return [Text.Encoding]::ASCII.GetString($bytes.ToArray())
        }
        $bytes.Add([byte]$value)
    }
    throw 'The agent returned an overlong response line.'
}

function Invoke-LineCommand {
    param([string]$Command)
    $connection = Open-AgentConnection
    try {
        Write-AgentLine -Stream $connection.Stream -Line $Command
        Read-AgentLineRaw -Stream $connection.Stream
    } finally {
        $connection.Stream.Dispose()
        $connection.Client.Dispose()
    }
}

function Send-AgentFile {
    param([string]$RemotePath, [byte[]]$Data)
    $connection = Open-AgentConnection
    try {
        Write-AgentLine -Stream $connection.Stream -Line "PUT $RemotePath $($Data.Length)"
        $ready = Read-AgentLineRaw -Stream $connection.Stream
        if ($ready -ne "OK READY $RemotePath $($Data.Length)") {
            throw "Unexpected PUT readiness response: $ready"
        }
        $connection.Stream.Write($Data, 0, $Data.Length)
        $connection.Stream.Flush()
        $completed = Read-AgentLineRaw -Stream $connection.Stream
        if ($completed -ne "OK PUT $RemotePath $($Data.Length)") {
            throw "Unexpected PUT completion response: $completed"
        }
        [ordered]@{ ready = $ready; completed = $completed }
    } finally {
        $connection.Stream.Dispose()
        $connection.Client.Dispose()
    }
}

function Receive-AgentFile {
    param([string]$RemotePath)
    $connection = Open-AgentConnection
    try {
        Write-AgentLine -Stream $connection.Stream -Line "GET $RemotePath"
        $header = Read-AgentLineRaw -Stream $connection.Stream
        $pattern = '^OK GET ' + [regex]::Escape($RemotePath) + ' ([0-9]+)$'
        if ($header -notmatch $pattern) {
            throw "Unexpected GET response: $header"
        }
        $length = [int]$Matches[1]
        $data = [byte[]]::new($length)
        $offset = 0
        while ($offset -lt $length) {
            $read = $connection.Stream.Read($data, $offset, $length - $offset)
            if ($read -le 0) { throw "The agent closed GET after $offset of $length bytes." }
            $offset += $read
        }
        [pscustomobject]@{ Header = $header; Data = $data }
    } finally {
        $connection.Stream.Dispose()
        $connection.Client.Dispose()
    }
}

$resolvedElf = (Resolve-Path -LiteralPath $ElfPath).Path
$elfHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedElf).Hash.ToLowerInvariant()
$expectedIdentity = Get-VitaLabElfIdentity -ElfPath $resolvedElf
$startedAt = [DateTime]::UtcNow
$timestamp = $startedAt.ToString('yyyyMMddTHHmmssfffZ')
$remotePath = "transfer-tests/$timestamp-roundtrip.bin"
$payload = [byte[]]::new($PayloadSize)
[Security.Cryptography.RandomNumberGenerator]::Fill($payload)
$sourceHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payload)).ToLowerInvariant()
$responses = [ordered]@{}
$download = $null
$downloadHash = $null
$agentVersion = $null
$buildId = $null
$gitCommit = $null
$result = 'FAIL'
$failure = $null

try {
    $responses.INVALID_GET_PATH = Invoke-LineCommand 'GET ../escape.bin'
    if ($responses.INVALID_GET_PATH -ne 'ERR INVALID_PATH') {
        throw "Traversal path was not rejected: $($responses.INVALID_GET_PATH)"
    }
    $responses.INVALID_PUT_PATH = Invoke-LineCommand 'PUT /absolute.bin 1'
    if ($responses.INVALID_PUT_PATH -ne 'ERR INVALID_PATH') {
        throw "Absolute path was not rejected: $($responses.INVALID_PUT_PATH)"
    }
    $responses.OVERSIZE_PUT = Invoke-LineCommand 'PUT oversize.bin 268435457'
    if ($responses.OVERSIZE_PUT -ne 'ERR INVALID_SIZE') {
        throw "Oversize PUT was not rejected: $($responses.OVERSIZE_PUT)"
    }

    $responses.INFO_BEFORE = Invoke-LineCommand 'INFO'
    if ($responses.INFO_BEFORE -notmatch '^VITALAB/1 INFO version=([^ ]+) platform=psvita build=([^ ]+) commit=([^ ]+)$') {
        throw "Unexpected INFO response: $($responses.INFO_BEFORE)"
    }
    $agentVersion = $Matches[1]
    $buildId = $Matches[2]
    $gitCommit = $Matches[3]
    Assert-VitaLabIdentityMatchesElf -Expected $expectedIdentity -AgentVersion $agentVersion -BuildId $buildId -GitCommit $gitCommit

    $responses.PUT = Send-AgentFile -RemotePath $remotePath -Data $payload
    $received = Receive-AgentFile -RemotePath $remotePath
    $responses.GET = $received.Header
    $download = $received.Data
    $downloadHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($download)).ToLowerInvariant()
    if ($download.Length -ne $payload.Length -or $downloadHash -ne $sourceHash) {
        throw "Round-trip mismatch: source=$sourceHash downloaded=$downloadHash."
    }

    $responses.PING_AFTER = Invoke-LineCommand 'PING'
    $responses.INFO_AFTER = Invoke-LineCommand 'INFO'
    if ($responses.PING_AFTER -ne 'PONG') { throw 'Post-transfer PING failed.' }
    if ($responses.INFO_AFTER -ne $responses.INFO_BEFORE) { throw 'Agent identity changed during transfer.' }
    $result = 'PASS'
} catch {
    $failure = $_.Exception.Message
}

$finishedAt = [DateTime]::UtcNow
$safeBuildId = if ($null -ne $buildId) { $buildId -replace '[^A-Za-z0-9._-]', '_' } else { 'unknown-build' }
$runDirectory = Join-Path $RunRoot "$timestamp-file-transfer-$safeBuildId"
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
Copy-Item -LiteralPath $resolvedElf -Destination (Join-Path $runDirectory 'vitalab-agent.elf')
[IO.File]::WriteAllBytes((Join-Path $runDirectory 'source.bin'), $payload)
if ($null -ne $download) { [IO.File]::WriteAllBytes((Join-Path $runDirectory 'downloaded.bin'), $download) }

$manifest = [ordered]@{
    schemaVersion = 1
    test = 'file-transfer-roundtrip'
    result = $result
    startedAtUtc = $startedAt.ToString('o')
    finishedAtUtc = $finishedAt.ToString('o')
    target = [ordered]@{ address = $Address; port = $Port; platform = 'psvita' }
    remotePath = $remotePath
    payloadSize = $payload.Length
    sourceSha256 = $sourceHash
    downloadedSha256 = $downloadHash
    identity = [ordered]@{ agentVersion = $agentVersion; buildId = $buildId; gitCommit = $gitCommit }
    elf = [ordered]@{ file = 'vitalab-agent.elf'; sha256 = $elfHash; sourcePath = $resolvedElf }
    responses = $responses
    failure = $failure
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDirectory 'manifest.json') -Encoding utf8

[pscustomobject]@{
    Result = $result
    Endpoint = "${Address}:$Port"
    RemotePath = $remotePath
    Bytes = $payload.Length
    SourceSha256 = $sourceHash
    DownloadedSha256 = $downloadHash
    BuildId = $buildId
    ElfSha256 = $elfHash
    RunDirectory = (Resolve-Path -LiteralPath $runDirectory).Path
}
if ($result -ne 'PASS') { throw "VitaLab file-transfer test failed: $failure" }
