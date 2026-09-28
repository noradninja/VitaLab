[CmdletBinding()]
param(
    [string]$Address = '192.168.2.222',
    [ValidateRange(1, 65535)]
    [int]$Port = 19600,
    [ValidateRange(100, 60000)]
    [int]$TimeoutMs = 5000,
    [string]$ElfPath = (Join-Path $PSScriptRoot '..\build-vita-plugin\vitalab'),
    [string]$RunRoot = (Join-Path $PSScriptRoot '..\runs')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VitaLabHostCommon.ps1')

function Read-AgentLine {
    param(
        [System.IO.StreamReader]$Reader,
        [int]$Timeout
    )

    $readTask = $Reader.ReadLineAsync()
    if (-not $readTask.Wait($Timeout)) {
        throw "Timed out waiting for the VitaLab agent after $Timeout ms."
    }
    if ($null -eq $readTask.Result) {
        throw 'The VitaLab agent closed the connection.'
    }
    return $readTask.Result
}

function Invoke-AgentCommand {
    param(
        [System.IO.StreamWriter]$Writer,
        [System.IO.StreamReader]$Reader,
        [string]$Command,
        [int]$Timeout
    )

    $Writer.WriteLine($Command)
    $Writer.Flush()
    return Read-AgentLine -Reader $Reader -Timeout $Timeout
}

$resolvedElf = (Resolve-Path -LiteralPath $ElfPath).Path
$elfHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedElf).Hash.ToLowerInvariant()
$expectedIdentity = Get-VitaLabElfIdentity -ElfPath $resolvedElf

$client = [System.Net.Sockets.TcpClient]::new()
try {
    $connectTask = $client.ConnectAsync($Address, $Port)
    if (-not $connectTask.Wait($TimeoutMs)) {
        throw "Timed out connecting to ${Address}:$Port after $TimeoutMs ms."
    }
    if ($connectTask.IsFaulted) {
        throw $connectTask.Exception.GetBaseException()
    }

    $stream = $client.GetStream()
    $reader = [System.IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
    $writer = [System.IO.StreamWriter]::new($stream, [Text.Encoding]::ASCII, 1024, $true)
    $writer.NewLine = "`n"

    $responses = [ordered]@{}
    $responses.HELLO = Invoke-AgentCommand $writer $reader 'HELLO' $TimeoutMs
    $responses.PING = Invoke-AgentCommand $writer $reader 'PING' $TimeoutMs
    $responses.INFO = Invoke-AgentCommand $writer $reader 'INFO' $TimeoutMs

    if ($responses.HELLO -ne 'VITALAB/1 READY') {
        throw "Unexpected HELLO response: $($responses.HELLO)"
    }
    if ($responses.PING -ne 'PONG') {
        throw "Unexpected PING response: $($responses.PING)"
    }
    if ($responses.INFO -notmatch '^VITALAB/1 INFO version=([^ ]+) platform=psvita build=([^ ]+) commit=([^ ]+)$') {
        throw "Unexpected INFO response: $($responses.INFO)"
    }

    $agentVersion = $Matches[1]
    $buildId = $Matches[2]
    $agentCommit = $Matches[3]
    Assert-VitaLabIdentityMatchesElf -Expected $expectedIdentity -AgentVersion $agentVersion -BuildId $buildId -GitCommit $agentCommit
    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $safeBuildId = $buildId -replace '[^A-Za-z0-9._-]', '_'
    $runDirectory = Join-Path $RunRoot "$timestamp-$safeBuildId"
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    Copy-Item -LiteralPath $resolvedElf -Destination (Join-Path $runDirectory 'vitalab-agent.elf')

    $manifest = [ordered]@{
        schemaVersion = 1
        recordedAtUtc = [DateTime]::UtcNow.ToString('o')
        target = [ordered]@{ address = $Address; port = $Port; platform = 'psvita' }
        protocolVersion = 1
        agentVersion = $agentVersion
        buildId = $buildId
        gitCommit = $agentCommit
        elf = [ordered]@{
            file = 'vitalab-agent.elf'
            sha256 = $elfHash
            sourcePath = $resolvedElf
        }
        responses = $responses
        result = 'PASS'
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runDirectory 'manifest.json') -Encoding utf8

    [pscustomobject]@{
        Result = 'PASS'
        Endpoint = "${Address}:$Port"
        Protocol = 'VITALAB/1'
        AgentVersion = $agentVersion
        BuildId = $buildId
        GitCommit = $agentCommit
        ElfSha256 = $elfHash
        RunDirectory = (Resolve-Path -LiteralPath $runDirectory).Path
    }
} finally {
    if ($null -ne $writer) { $writer.Dispose() }
    if ($null -ne $reader) { $reader.Dispose() }
    $client.Dispose()
}
