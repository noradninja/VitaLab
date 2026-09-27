[CmdletBinding()]
param(
    [string]$Address = '192.168.2.222',
    [ValidateRange(1, 65535)]
    [int]$Port = 19600,
    [ValidateRange(1, 10000)]
    [int]$Iterations = 100,
    [ValidateRange(0, 60000)]
    [int]$DelayMs = 50,
    [ValidateRange(100, 60000)]
    [int]$TimeoutMs = 3000,
    [string]$ElfPath = (Join-Path $PSScriptRoot '..\build-vita-plugin\vitalab'),
    [string]$RunRoot = (Join-Path $PSScriptRoot '..\runs')
)

$ErrorActionPreference = 'Stop'

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

function Invoke-StressIteration {
    param(
        [string]$TargetAddress,
        [int]$TargetPort,
        [int]$Timeout
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    $reader = $null
    $writer = $null
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $connectTask = $client.ConnectAsync($TargetAddress, $TargetPort)
        if (-not $connectTask.Wait($Timeout)) {
            throw "Timed out connecting to ${TargetAddress}:$TargetPort after $Timeout ms."
        }
        if ($connectTask.IsFaulted) {
            throw $connectTask.Exception.GetBaseException()
        }

        $stream = $client.GetStream()
        $reader = [System.IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
        $writer = [System.IO.StreamWriter]::new($stream, [Text.Encoding]::ASCII, 1024, $true)
        $writer.NewLine = "`n"

        $hello = Invoke-AgentCommand $writer $reader 'HELLO' $Timeout
        $ping = Invoke-AgentCommand $writer $reader 'PING' $Timeout
        $info = Invoke-AgentCommand $writer $reader 'INFO' $Timeout

        if ($hello -ne 'VITALAB/1 READY') {
            throw "Unexpected HELLO response: $hello"
        }
        if ($ping -ne 'PONG') {
            throw "Unexpected PING response: $ping"
        }
        if ($info -notmatch '^VITALAB/1 INFO version=([^ ]+) platform=psvita build=([^ ]+) commit=([^ ]+)$') {
            throw "Unexpected INFO response: $info"
        }

        $stopwatch.Stop()
        return [pscustomobject]@{
            durationMs = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 3)
            agentVersion = $Matches[1]
            buildId = $Matches[2]
            gitCommit = $Matches[3]
            hello = $hello
            ping = $ping
            info = $info
        }
    } finally {
        $stopwatch.Stop()
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $reader) { $reader.Dispose() }
        $client.Dispose()
    }
}

$resolvedElf = (Resolve-Path -LiteralPath $ElfPath).Path
$elfHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedElf).Hash.ToLowerInvariant()
$startedAt = [DateTime]::UtcNow
$records = [System.Collections.Generic.List[object]]::new()
$identity = $null
$failure = $null

for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
    try {
        $sample = Invoke-StressIteration -TargetAddress $Address -TargetPort $Port -Timeout $TimeoutMs
        if ($null -eq $identity) {
            $identity = [ordered]@{
                agentVersion = $sample.agentVersion
                buildId = $sample.buildId
                gitCommit = $sample.gitCommit
            }
        } elseif ($sample.buildId -ne $identity.buildId -or
                  $sample.gitCommit -ne $identity.gitCommit -or
                  $sample.agentVersion -ne $identity.agentVersion) {
            throw "Agent identity changed during iteration $iteration."
        }

        $records.Add([ordered]@{
            iteration = $iteration
            result = 'PASS'
            durationMs = $sample.durationMs
            responses = [ordered]@{
                HELLO = $sample.hello
                PING = $sample.ping
                INFO = $sample.info
            }
        })
    } catch {
        $failure = $_.Exception.Message
        $records.Add([ordered]@{
            iteration = $iteration
            result = 'FAIL'
            error = $failure
        })
        break
    }

    if ($DelayMs -gt 0 -and $iteration -lt $Iterations) {
        Start-Sleep -Milliseconds $DelayMs
    }
}

$finishedAt = [DateTime]::UtcNow
$passed = @($records | Where-Object result -eq 'PASS')
$durations = @($passed | ForEach-Object durationMs | Sort-Object)
$metrics = [ordered]@{
    minimumMs = $null
    averageMs = $null
    p95Ms = $null
    maximumMs = $null
}
if ($durations.Count -gt 0) {
    $p95Index = [Math]::Max(0, [Math]::Ceiling($durations.Count * 0.95) - 1)
    $metrics.minimumMs = $durations[0]
    $metrics.averageMs = [Math]::Round(($durations | Measure-Object -Average).Average, 3)
    $metrics.p95Ms = $durations[$p95Index]
    $metrics.maximumMs = $durations[-1]
}

$result = if ($null -eq $failure -and $records.Count -eq $Iterations) { 'PASS' } else { 'FAIL' }
$timestamp = $startedAt.ToString('yyyyMMddTHHmmssfffZ')
$identityBuild = if ($null -ne $identity) { $identity.buildId } else { 'unknown-build' }
$safeBuildId = $identityBuild -replace '[^A-Za-z0-9._-]', '_'
$runDirectory = Join-Path $RunRoot "$timestamp-stress-$safeBuildId"
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
Copy-Item -LiteralPath $resolvedElf -Destination (Join-Path $runDirectory 'vitalab-agent.elf')

$manifest = [ordered]@{
    schemaVersion = 1
    test = 'connection-stress'
    result = $result
    startedAtUtc = $startedAt.ToString('o')
    finishedAtUtc = $finishedAt.ToString('o')
    target = [ordered]@{ address = $Address; port = $Port; platform = 'psvita' }
    requestedIterations = $Iterations
    completedIterations = $passed.Count
    delayMs = $DelayMs
    timeoutMs = $TimeoutMs
    identity = $identity
    elf = [ordered]@{
        file = 'vitalab-agent.elf'
        sha256 = $elfHash
        sourcePath = $resolvedElf
    }
    durationMetrics = $metrics
    failure = $failure
    iterations = $records
}
$manifest | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $runDirectory 'manifest.json') -Encoding utf8

$summary = [pscustomobject]@{
    Result = $result
    Endpoint = "${Address}:$Port"
    Completed = "$($passed.Count)/$Iterations"
    BuildId = $identityBuild
    ElfSha256 = $elfHash
    MinimumMs = $metrics.minimumMs
    AverageMs = $metrics.averageMs
    P95Ms = $metrics.p95Ms
    MaximumMs = $metrics.maximumMs
    RunDirectory = (Resolve-Path -LiteralPath $runDirectory).Path
}
$summary

if ($result -ne 'PASS') {
    throw "VitaLab stress test failed: $failure"
}
