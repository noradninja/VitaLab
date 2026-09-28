[CmdletBinding()]
param(
    [string]$Address = '192.168.2.222',
    [ValidateRange(1, 65535)]
    [int]$Port = 19600,
    [ValidateRange(100, 10000)]
    [int]$ProbeTimeoutMs = 1000,
    [ValidateRange(100, 10000)]
    [int]$PollIntervalMs = 1000,
    [ValidateRange(5, 300)]
    [int]$DisconnectTimeoutSeconds = 30,
    [ValidateRange(5, 600)]
    [int]$RecoveryTimeoutSeconds = 120,
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

    $task = $Reader.ReadLineAsync()
    if (-not $task.Wait($Timeout)) {
        throw "Timed out waiting for the agent after $Timeout ms."
    }
    if ($null -eq $task.Result) {
        throw 'The agent closed the connection.'
    }
    return $task.Result
}

function Invoke-AgentProbe {
    param(
        [string]$TargetAddress,
        [int]$TargetPort,
        [int]$Timeout
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    $reader = $null
    $writer = $null
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $connect = $client.ConnectAsync($TargetAddress, $TargetPort)
        if (-not $connect.Wait($Timeout)) {
            throw "Connection timed out after $Timeout ms."
        }
        if ($connect.IsFaulted) {
            throw $connect.Exception.GetBaseException()
        }

        $stream = $client.GetStream()
        $reader = [System.IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
        $writer = [System.IO.StreamWriter]::new($stream, [Text.Encoding]::ASCII, 1024, $true)
        $writer.NewLine = "`n"

        $responses = [ordered]@{}
        foreach ($command in @('HELLO', 'PING', 'INFO')) {
            $writer.WriteLine($command)
            $writer.Flush()
            $responses[$command] = Read-AgentLine -Reader $reader -Timeout $Timeout
        }

        if ($responses.HELLO -ne 'VITALAB/1 READY' -or $responses.PING -ne 'PONG') {
            throw 'The agent returned an invalid HELLO or PING response.'
        }
        if ($responses.INFO -notmatch '^VITALAB/1 INFO version=([^ ]+) platform=psvita build=([^ ]+) commit=([^ ]+)$') {
            throw "Unexpected INFO response: $($responses.INFO)"
        }

        $watch.Stop()
        return [pscustomobject]@{
            success = $true
            observedAtUtc = [DateTime]::UtcNow.ToString('o')
            durationMs = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3)
            agentVersion = $Matches[1]
            buildId = $Matches[2]
            gitCommit = $Matches[3]
            responses = $responses
            error = $null
        }
    } catch {
        $watch.Stop()
        return [pscustomobject]@{
            success = $false
            observedAtUtc = [DateTime]::UtcNow.ToString('o')
            durationMs = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3)
            agentVersion = $null
            buildId = $null
            gitCommit = $null
            responses = $null
            error = $_.Exception.Message
        }
    } finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $reader) { $reader.Dispose() }
        $client.Dispose()
    }
}

$resolvedElf = (Resolve-Path -LiteralPath $ElfPath).Path
$elfHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedElf).Hash.ToLowerInvariant()
$expectedIdentity = Get-VitaLabElfIdentity -ElfPath $resolvedElf
$startedAt = [DateTime]::UtcNow
$baseline = Invoke-AgentProbe -TargetAddress $Address -TargetPort $Port -Timeout $ProbeTimeoutMs
if (-not $baseline.success) {
    throw "Baseline probe failed: $($baseline.error)"
}
Assert-VitaLabIdentityMatchesElf -Expected $expectedIdentity -AgentVersion $baseline.agentVersion -BuildId $baseline.buildId -GitCommit $baseline.gitCommit

Write-Host "Baseline PASS for $($baseline.buildId)."
Read-Host 'Disconnect the Vita TV Ethernet cable, then press Enter'

$disconnectRequestedAt = [DateTime]::UtcNow
$disconnectDeadline = $disconnectRequestedAt.AddSeconds($DisconnectTimeoutSeconds)
$outageProbe = $null
do {
    $probe = Invoke-AgentProbe -TargetAddress $Address -TargetPort $Port -Timeout $ProbeTimeoutMs
    if (-not $probe.success) {
        $outageProbe = $probe
        break
    }
    Start-Sleep -Milliseconds $PollIntervalMs
} while ([DateTime]::UtcNow -lt $disconnectDeadline)

if ($null -eq $outageProbe) {
    throw "The endpoint remained reachable for $DisconnectTimeoutSeconds seconds after disconnect was requested."
}

Write-Host "Outage detected: $($outageProbe.error)"
Read-Host 'Reconnect the Vita TV Ethernet cable, then press Enter'

$reconnectConfirmedAt = [DateTime]::UtcNow
$recoveryDeadline = $reconnectConfirmedAt.AddSeconds($RecoveryTimeoutSeconds)
$recoveryAttempts = [System.Collections.Generic.List[object]]::new()
$recovered = $null
do {
    $probe = Invoke-AgentProbe -TargetAddress $Address -TargetPort $Port -Timeout $ProbeTimeoutMs
    $recoveryAttempts.Add($probe)
    if ($probe.success) {
        if ($probe.buildId -ne $baseline.buildId -or
            $probe.gitCommit -ne $baseline.gitCommit -or
            $probe.agentVersion -ne $baseline.agentVersion) {
            throw 'Agent identity changed after network recovery.'
        }
        $recovered = $probe
        break
    }
    Start-Sleep -Milliseconds $PollIntervalMs
} while ([DateTime]::UtcNow -lt $recoveryDeadline)

$finishedAt = [DateTime]::UtcNow
$result = if ($null -ne $recovered) { 'PASS' } else { 'FAIL' }
$detectionAfterReconnectConfirmSeconds = if ($null -ne $recovered) {
    [Math]::Round(($finishedAt - $reconnectConfirmedAt).TotalSeconds, 3)
} else {
    $null
}

$timestamp = $startedAt.ToString('yyyyMMddTHHmmssfffZ')
$safeBuildId = $baseline.buildId -replace '[^A-Za-z0-9._-]', '_'
$runDirectory = Join-Path $RunRoot "$timestamp-network-recovery-$safeBuildId"
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
Copy-Item -LiteralPath $resolvedElf -Destination (Join-Path $runDirectory 'vitalab-agent.elf')

$manifest = [ordered]@{
    schemaVersion = 1
    test = 'network-disconnect-recovery'
    result = $result
    startedAtUtc = $startedAt.ToString('o')
    finishedAtUtc = $finishedAt.ToString('o')
    target = [ordered]@{ address = $Address; port = $Port; platform = 'psvita' }
    identity = [ordered]@{
        agentVersion = $baseline.agentVersion
        buildId = $baseline.buildId
        gitCommit = $baseline.gitCommit
    }
    elf = [ordered]@{
        file = 'vitalab-agent.elf'
        sha256 = $elfHash
        sourcePath = $resolvedElf
    }
    baseline = $baseline
    disconnectRequestedAtUtc = $disconnectRequestedAt.ToString('o')
    outageDetectedAtUtc = $outageProbe.observedAtUtc
    outageError = $outageProbe.error
    reconnectConfirmedAtUtc = $reconnectConfirmedAt.ToString('o')
    detectionAfterReconnectConfirmSeconds = $detectionAfterReconnectConfirmSeconds
    recoveryAttempts = $recoveryAttempts
    recovered = $recovered
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDirectory 'manifest.json') -Encoding utf8

[pscustomobject]@{
    Result = $result
    Endpoint = "${Address}:$Port"
    BuildId = $baseline.buildId
    OutageDetected = $true
    RecoveryAttempts = $recoveryAttempts.Count
    DetectionAfterConfirmSeconds = $detectionAfterReconnectConfirmSeconds
    ElfSha256 = $elfHash
    RunDirectory = (Resolve-Path -LiteralPath $runDirectory).Path
}

if ($result -ne 'PASS') {
    throw "The VitaLab agent did not recover within $RecoveryTimeoutSeconds seconds."
}
