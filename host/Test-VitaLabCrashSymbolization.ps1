[CmdletBinding()]
param(
    [string]$Address = '192.168.2.222',
    [ValidateRange(1, 65535)]
    [int]$Port = 19600,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Z0-9]{9}$')]
    [string]$TitleId,
    [Parameter(Mandatory = $true)]
    [string]$TargetElfPath,
    [Parameter(Mandatory = $true)]
    [string]$TargetPackagePath,
    [string]$TargetModuleName,
    [ValidateRange(1, 300)]
    [int]$LaunchTimeoutSeconds = 30,
    [ValidateRange(5, 1800)]
    [int]$CrashTimeoutSeconds = 300,
    [ValidateRange(1, 300)]
    [int]$DumpTimeoutSeconds = 60,
    [ValidateRange(100, 10000)]
    [int]$PollIntervalMs = 500,
    [ValidateRange(100, 60000)]
    [int]$TimeoutMs = 5000,
    [switch]$SkipCrashDialogConfirmation,
    [string]$VitaSdkPath = 'E:\dev\VitaSDK',
    [string]$AgentElfPath = (Join-Path $PSScriptRoot '..\build-vita-plugin\vitalab'),
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

function Read-AgentLine {
    param([System.IO.Stream]$Stream)
    $bytes = [Collections.Generic.List[byte]]::new()
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

function Invoke-AgentLine {
    param([string]$Command)
    $connection = Open-AgentConnection
    try { Write-AgentLine $connection.Stream $Command; Read-AgentLine $connection.Stream }
    finally { $connection.Stream.Dispose(); $connection.Client.Dispose() }
}

function Get-DumpList {
    $connection = Open-AgentConnection
    try {
        Write-AgentLine $connection.Stream 'LIST DUMPS'
        $header = Read-AgentLine $connection.Stream
        if ($header -ne 'OK DUMPS') { throw "Unexpected dump-list response: $header" }
        $items = [Collections.Generic.List[object]]::new()
        for (;;) {
            $line = Read-AgentLine $connection.Stream
            if ($line -eq 'END DUMPS') { break }
            if ($line -notmatch '^DUMP (psp2core-[A-Za-z0-9._-]+\.psp2dmp) ([0-9]+)$') {
                throw "Unexpected dump-list entry: $line"
            }
            $items.Add([pscustomobject]@{ Name = $Matches[1]; Size = [int64]$Matches[2] })
        }
        return $items
    } finally { $connection.Stream.Dispose(); $connection.Client.Dispose() }
}

function Receive-Dump {
    param([string]$Name, [int64]$ExpectedSize)
    if ($ExpectedSize -gt [int]::MaxValue) { throw "Dump $Name is too large for the host receiver." }
    $connection = Open-AgentConnection
    try {
        Write-AgentLine $connection.Stream "GET DUMP $Name"
        $header = Read-AgentLine $connection.Stream
        $pattern = '^OK DUMP ' + [regex]::Escape($Name) + ' ([0-9]+)$'
        if ($header -notmatch $pattern) { throw "Unexpected dump response: $header" }
        $length = [int]$Matches[1]
        if ($length -ne $ExpectedSize) { throw "Dump size changed from $ExpectedSize to $length bytes." }
        $data = [byte[]]::new($length)
        $offset = 0
        while ($offset -lt $length) {
            $read = $connection.Stream.Read($data, $offset, $length - $offset)
            if ($read -le 0) { throw "The agent closed after $offset of $length dump bytes." }
            $offset += $read
        }
        return $data
    } finally { $connection.Stream.Dispose(); $connection.Client.Dispose() }
}

function Get-Status {
    $observedAt = [DateTime]::UtcNow
    $response = Invoke-AgentLine "STATUS $TitleId"
    if ($response -notmatch ('^OK STATUS ' + [regex]::Escape($TitleId) + ' (RUNNING|STOPPED)$')) {
        throw "Unexpected STATUS response: $response"
    }
    [pscustomobject]@{ observedAtUtc = $observedAt.ToString('o'); state = $Matches[1]; response = $response }
}

function Find-GitRoot {
    param([string]$Path)
    $current = Get-Item -LiteralPath (Split-Path -Parent $Path)
    while ($null -ne $current) {
        if (Test-Path -LiteralPath (Join-Path $current.FullName '.git')) { return $current.FullName }
        $current = $current.Parent
    }
    return $null
}

$agentElf = (Resolve-Path -LiteralPath $AgentElfPath).Path
$targetElf = (Resolve-Path -LiteralPath $TargetElfPath).Path
$targetPackage = (Resolve-Path -LiteralPath $TargetPackagePath).Path
$agentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $agentElf).Hash.ToLowerInvariant()
$targetElfHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetElf).Hash.ToLowerInvariant()
$targetPackageHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetPackage).Hash.ToLowerInvariant()
$expectedIdentity = Get-VitaLabElfIdentity -ElfPath $agentElf
$targetGitRoot = Find-GitRoot -Path $targetElf
$targetGitCommit = if ($null -ne $targetGitRoot) { (& git -C $targetGitRoot rev-parse HEAD).Trim() } else { $null }
$targetGitDirty = if ($null -ne $targetGitRoot) { [bool](& git -C $targetGitRoot status --porcelain --untracked-files=no) } else { $null }
$startedAt = [DateTime]::UtcNow
$timestamp = $startedAt.ToString('yyyyMMddTHHmmssfffZ')
$runDirectory = Join-Path $RunRoot "$timestamp-crash-symbolization-$TitleId"
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
Copy-Item -LiteralPath $agentElf -Destination (Join-Path $runDirectory 'vitalab-agent.elf')
Copy-Item -LiteralPath $targetElf -Destination (Join-Path $runDirectory 'target.elf')
Copy-Item -LiteralPath $targetPackage -Destination (Join-Path $runDirectory ('target' + [IO.Path]::GetExtension($targetPackage)))

$responses = [ordered]@{}
$statusSamples = [Collections.Generic.List[object]]::new()
$beforeDumps = @()
$afterDumps = @()
$newDumps = @()
$symbolizations = [Collections.Generic.List[object]]::new()
$agentVersion = $null; $buildId = $null; $gitCommit = $null
$failure = $null; $result = 'FAIL'; $launched = $false
$crashDialogConfirmedAt = $null

try {
    $responses.INFO_BEFORE = Invoke-AgentLine 'INFO'
    if ($responses.INFO_BEFORE -notmatch '^VITALAB/1 INFO version=([^ ]+) platform=psvita build=([^ ]+) commit=([^ ]+)$') {
        throw "Unexpected INFO response: $($responses.INFO_BEFORE)"
    }
    $agentVersion = $Matches[1]; $buildId = $Matches[2]; $gitCommit = $Matches[3]
    Assert-VitaLabIdentityMatchesElf -Expected $expectedIdentity -AgentVersion $agentVersion -BuildId $buildId -GitCommit $gitCommit

    $initial = Get-Status
    $statusSamples.Add($initial)
    if ($initial.state -ne 'STOPPED') { throw "Title $TitleId must begin stopped." }
    $beforeDumps = @(Get-DumpList)
    $beforeNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($dump in $beforeDumps) { [void]$beforeNames.Add($dump.Name) }

    $responses.LAUNCH = Invoke-AgentLine "LAUNCH $TitleId"
    if ($responses.LAUNCH -ne "OK LAUNCH $TitleId") { throw "Launch failed: $($responses.LAUNCH)" }
    $launched = $true
    Write-Host 'If the Vita asks to close the current application, approve the close dialog.'
    Write-Host "Title $TitleId launched. Reproduce the expected crash within $CrashTimeoutSeconds seconds."

    $launchDeadline = [DateTime]::UtcNow.AddSeconds($LaunchTimeoutSeconds)
    do {
        $sample = Get-Status
        $statusSamples.Add($sample)
        if ($sample.state -eq 'RUNNING') { break }
        Start-Sleep -Milliseconds $PollIntervalMs
    } while ([DateTime]::UtcNow -lt $launchDeadline)

    $crashDeadline = [DateTime]::UtcNow.AddSeconds($CrashTimeoutSeconds)
    do {
        $sample = Get-Status
        $statusSamples.Add($sample)
        if ($sample.state -eq 'STOPPED') { $launched = $false; break }
        $responses.PING_RUNNING = Invoke-AgentLine 'PING'
        if ($responses.PING_RUNNING -ne 'PONG') { throw 'Agent stopped responding while the target was running.' }
        Start-Sleep -Milliseconds $PollIntervalMs
    } while ([DateTime]::UtcNow -lt $crashDeadline)
    if ($launched) { throw "Title $TitleId did not stop within $CrashTimeoutSeconds seconds." }

    $dumpDeadline = [DateTime]::UtcNow.AddSeconds($DumpTimeoutSeconds)
    do {
        $afterDumps = @(Get-DumpList)
        $newDumps = @($afterDumps | Where-Object { -not $beforeNames.Contains($_.Name) })
        if ($newDumps.Count -gt 0) { break }
        Start-Sleep -Milliseconds $PollIntervalMs
    } while ([DateTime]::UtcNow -lt $dumpDeadline)
    if ($newDumps.Count -eq 0) { throw "No new core dump appeared within $DumpTimeoutSeconds seconds." }

    foreach ($dump in $newDumps) {
        $dumpPath = Join-Path $runDirectory $dump.Name
        $dumpData = Receive-Dump -Name $dump.Name -ExpectedSize $dump.Size
        [IO.File]::WriteAllBytes($dumpPath, $dumpData)
        $symbolDirectory = Join-Path $runDirectory ([IO.Path]::GetFileNameWithoutExtension($dump.Name))
        $symbolArguments = @{
            DumpPath = $dumpPath
            TargetElfPath = (Join-Path $runDirectory 'target.elf')
            VitaSdkPath = $VitaSdkPath
            OutputDirectory = $symbolDirectory
        }
        if (-not [string]::IsNullOrWhiteSpace($TargetModuleName)) { $symbolArguments.ModuleName = $TargetModuleName }
        $symbol = & (Join-Path $PSScriptRoot 'Invoke-VitaLabCoreSymbolization.ps1') @symbolArguments
        $symbolizations.Add($symbol)
    }

    if (-not ($symbolizations | Where-Object { $_.Function -and $_.Function -ne '??' })) {
        throw 'The new dump did not resolve its crash PC to a target-ELF function.'
    }
    if (-not $SkipCrashDialogConfirmation) {
        Read-Host 'The new dump is archived. Clear the Vita crash dialog, wait for LiveArea, then press Enter' | Out-Null
        $crashDialogConfirmedAt = [DateTime]::UtcNow
        $responses.STATUS_AFTER_CRASH_DIALOG = (Get-Status).response
    }
    $responses.PING_AFTER = Invoke-AgentLine 'PING'
    $responses.INFO_AFTER = Invoke-AgentLine 'INFO'
    if ($responses.PING_AFTER -ne 'PONG' -or $responses.INFO_AFTER -ne $responses.INFO_BEFORE) {
        throw 'Agent health or identity changed during the crash test.'
    }
    $result = 'PASS'
} catch {
    $failure = $_.Exception.Message
    if ($launched) {
        try { $responses.CLEANUP = Invoke-AgentLine "STOP $TitleId" }
        catch { $responses.CLEANUP = "CLEANUP FAILED: $($_.Exception.Message)" }
    }
}

$finishedAt = [DateTime]::UtcNow
$manifest = [ordered]@{
    schemaVersion = 1; test = 'crash-symbolization'; result = $result
    startedAtUtc = $startedAt.ToString('o'); finishedAtUtc = $finishedAt.ToString('o')
    target = [ordered]@{ address = $Address; port = $Port; platform = 'psvita'; titleId = $TitleId }
    agent = [ordered]@{ version = $agentVersion; buildId = $buildId; gitCommit = $gitCommit; elfFile = 'vitalab-agent.elf'; elfSha256 = $agentHash }
    application = [ordered]@{
        elfFile = 'target.elf'; elfSha256 = $targetElfHash; sourcePath = $targetElf
        packageFile = ('target' + [IO.Path]::GetExtension($targetPackage)); packageSha256 = $targetPackageHash; packageSourcePath = $targetPackage
        gitRoot = $targetGitRoot; gitCommit = $targetGitCommit; gitDirty = $targetGitDirty; moduleName = $TargetModuleName
    }
    dumpsBefore = $beforeDumps; dumpsAfter = $afterDumps; newDumps = $newDumps
    statusSamples = $statusSamples; symbolizations = $symbolizations; responses = $responses; failure = $failure
    manualActions = [ordered]@{
        launchCloseDialogInstructionShown = $true
        crashDialogConfirmationRequired = (-not $SkipCrashDialogConfirmation)
        crashDialogConfirmedAtUtc = if ($null -ne $crashDialogConfirmedAt) { $crashDialogConfirmedAt.ToString('o') } else { $null }
    }
}
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $runDirectory 'manifest.json') -Encoding utf8

[pscustomobject]@{
    Result = $result; Endpoint = "${Address}:$Port"; TitleId = $TitleId
    NewDumps = $newDumps.Count; SymbolizedDumps = $symbolizations.Count
    CrashFunction = if ($symbolizations.Count -gt 0) { $symbolizations[0].Function } else { $null }
    CrashLocation = if ($symbolizations.Count -gt 0) { $symbolizations[0].Location } else { $null }
    CrashDialogConfirmed = ($null -ne $crashDialogConfirmedAt)
    TargetElfSha256 = $targetElfHash; TargetPackageSha256 = $targetPackageHash
    BuildId = $buildId; AgentElfSha256 = $agentHash
    RunDirectory = (Resolve-Path -LiteralPath $runDirectory).Path
}
if ($result -ne 'PASS') { throw "VitaLab crash-symbolization test failed: $failure" }
