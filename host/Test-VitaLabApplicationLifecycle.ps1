[CmdletBinding()]
param(
    [string]$Address = '192.168.2.222',
    [ValidateRange(1, 65535)]
    [int]$Port = 19600,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Z0-9]{9}$')]
    [string]$TitleId,
    [ValidateRange(1, 300)]
    [int]$LaunchTimeoutSeconds = 30,
    [ValidateRange(5, 1800)]
    [int]$ExitTimeoutSeconds = 300,
    [ValidateRange(100, 10000)]
    [int]$PollIntervalMs = 500,
    [ValidateRange(100, 60000)]
    [int]$TimeoutMs = 5000,
    [string]$ElfPath = (Join-Path $PSScriptRoot '..\build-vita-plugin\vitalab'),
    [string]$RunRoot = (Join-Path $PSScriptRoot '..\runs')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VitaLabHostCommon.ps1')

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

function Get-StatusSample {
    $observedAt = [DateTime]::UtcNow
    $response = Invoke-AgentLine "STATUS $TitleId"
    $expectedPrefix = "OK STATUS $TitleId "
    if (-not $response.StartsWith($expectedPrefix)) {
        throw "Unexpected STATUS response: $response"
    }

    $state = $response.Substring($expectedPrefix.Length)
    if ($state -ne 'RUNNING' -and $state -ne 'STOPPED') {
        throw "Unexpected STATUS state: $state"
    }

    [pscustomobject]@{
        observedAtUtc = $observedAt.ToString('o')
        state = $state
        response = $response
    }
}

function Wait-ForState {
    param(
        [string]$ExpectedState,
        [int]$TimeoutSeconds,
        [System.Collections.Generic.List[object]]$Samples
    )

    $started = [DateTime]::UtcNow
    $deadline = $started.AddSeconds($TimeoutSeconds)
    do {
        $sample = Get-StatusSample
        $Samples.Add($sample)
        if ($sample.state -eq $ExpectedState) {
            return [pscustomobject]@{
                observedAtUtc = $sample.observedAtUtc
                elapsedSeconds = [Math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 3)
                attempts = $Samples.Count
            }
        }
        Start-Sleep -Milliseconds $PollIntervalMs
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Title $TitleId did not reach $ExpectedState within $TimeoutSeconds seconds."
}

$resolvedElf = (Resolve-Path -LiteralPath $ElfPath).Path
$elfHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedElf).Hash.ToLowerInvariant()
$expectedIdentity = Get-VitaLabElfIdentity -ElfPath $resolvedElf
$startedAt = [DateTime]::UtcNow
$responses = [ordered]@{}
$launchSamples = [System.Collections.Generic.List[object]]::new()
$exitSamples = [System.Collections.Generic.List[object]]::new()
$result = 'FAIL'
$failure = $null
$cleanupResponse = $null
$agentVersion = $null
$buildId = $null
$gitCommit = $null
$initialState = $null
$runningDetection = $null
$exitDetection = $null
$launched = $false

try {
    $responses.STATUS_MALFORMED = Invoke-AgentLine 'STATUS SHORT'
    if ($responses.STATUS_MALFORMED -ne 'ERR INVALID_TITLE_ID') {
        throw "Malformed title ID was not rejected: $($responses.STATUS_MALFORMED)"
    }
    $responses.STATUS_LOWERCASE = Invoke-AgentLine 'STATUS aaaaaaaaa'
    if ($responses.STATUS_LOWERCASE -ne 'ERR INVALID_TITLE_ID') {
        throw "Lowercase title ID was not rejected: $($responses.STATUS_LOWERCASE)"
    }

    $responses.INFO_BEFORE = Invoke-AgentLine 'INFO'
    if ($responses.INFO_BEFORE -notmatch '^VITALAB/1 INFO version=([^ ]+) platform=psvita build=([^ ]+) commit=([^ ]+)$') {
        throw "Unexpected initial INFO response: $($responses.INFO_BEFORE)"
    }
    $agentVersion = $Matches[1]
    $buildId = $Matches[2]
    $gitCommit = $Matches[3]
    Assert-VitaLabIdentityMatchesElf -Expected $expectedIdentity -AgentVersion $agentVersion -BuildId $buildId -GitCommit $gitCommit

    $initialSample = Get-StatusSample
    $initialState = $initialSample.state
    $responses.STATUS_BEFORE = $initialSample.response
    if ($initialState -ne 'STOPPED') {
        throw "Title $TitleId must be stopped before the lifecycle test."
    }

    $responses.LAUNCH = Invoke-AgentLine "LAUNCH $TitleId"
    if ($responses.LAUNCH -ne "OK LAUNCH $TitleId") {
        throw "Launch failed: $($responses.LAUNCH)"
    }
    $launched = $true
    Write-Host 'If the Vita asks to close the current application, approve the close dialog.'

    $runningDetection = Wait-ForState -ExpectedState 'RUNNING' -TimeoutSeconds $LaunchTimeoutSeconds -Samples $launchSamples
    $responses.PING_RUNNING = Invoke-AgentLine 'PING'
    if ($responses.PING_RUNNING -ne 'PONG') {
        throw "Foreground PING failed: $($responses.PING_RUNNING)"
    }

    Write-Host "Title $TitleId is RUNNING. Exit the application normally on the Vita TV within $ExitTimeoutSeconds seconds."
    $exitDetection = Wait-ForState -ExpectedState 'STOPPED' -TimeoutSeconds $ExitTimeoutSeconds -Samples $exitSamples
    $launched = $false

    $responses.PING_AFTER_EXIT = Invoke-AgentLine 'PING'
    if ($responses.PING_AFTER_EXIT -ne 'PONG') {
        throw "Post-exit PING failed: $($responses.PING_AFTER_EXIT)"
    }
    $responses.INFO_AFTER = Invoke-AgentLine 'INFO'
    if ($responses.INFO_AFTER -ne $responses.INFO_BEFORE) {
        throw 'Agent identity changed after the application exited.'
    }

    $result = 'PASS'
} catch {
    $failure = $_.Exception.Message
    if ($launched) {
        try {
            $cleanupResponse = Invoke-AgentLine "STOP $TitleId"
        } catch {
            $cleanupResponse = "CLEANUP FAILED: $($_.Exception.Message)"
        }
    }
}

$finishedAt = [DateTime]::UtcNow
$safeBuildId = if ($null -ne $buildId) {
    $buildId -replace '[^A-Za-z0-9._-]', '_'
} else {
    'unknown-build'
}
$timestamp = $startedAt.ToString('yyyyMMddTHHmmssfffZ')
$runDirectory = Join-Path $RunRoot "$timestamp-application-lifecycle-$safeBuildId"
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
Copy-Item -LiteralPath $resolvedElf -Destination (Join-Path $runDirectory 'vitalab-agent.elf')

$manifest = [ordered]@{
    schemaVersion = 1
    test = 'application-lifecycle'
    result = $result
    startedAtUtc = $startedAt.ToString('o')
    finishedAtUtc = $finishedAt.ToString('o')
    target = [ordered]@{ address = $Address; port = $Port; platform = 'psvita' }
    controlledTitleId = $TitleId
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
    initialState = $initialState
    runningDetection = $runningDetection
    exitDetection = $exitDetection
    launchStatusSamples = $launchSamples
    exitStatusSamples = $exitSamples
    responses = $responses
    cleanupResponse = $cleanupResponse
    failure = $failure
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDirectory 'manifest.json') -Encoding utf8

[pscustomobject]@{
    Result = $result
    Endpoint = "${Address}:$Port"
    TitleId = $TitleId
    InitialState = $initialState
    RunningDetected = ($null -ne $runningDetection)
    NaturalExitDetected = ($null -ne $exitDetection)
    RunningDetectionSeconds = if ($null -ne $runningDetection) { $runningDetection.elapsedSeconds } else { $null }
    ExitDetectionSeconds = if ($null -ne $exitDetection) { $exitDetection.elapsedSeconds } else { $null }
    BuildId = $buildId
    ElfSha256 = $elfHash
    RunDirectory = (Resolve-Path -LiteralPath $runDirectory).Path
}

if ($result -ne 'PASS') {
    throw "VitaLab application-lifecycle test failed: $failure"
}
