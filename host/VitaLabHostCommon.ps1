function Get-VitaLabStringsTool {
    $command = Get-Command 'arm-vita-eabi-strings.exe' -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:VITASDK)) {
        $candidates.Add((Join-Path $env:VITASDK 'bin\arm-vita-eabi-strings.exe'))
    }
    $candidates.Add('E:\dev\VitaSDK-snapshopt\bin\arm-vita-eabi-strings.exe')

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw 'Could not find arm-vita-eabi-strings.exe. Add the VitaSDK bin directory to PATH or set VITASDK.'
}

function Get-VitaLabElfIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ElfPath
    )

    $resolvedElf = (Resolve-Path -LiteralPath $ElfPath).Path
    $stringsTool = Get-VitaLabStringsTool
    $infoPattern = '^VITALAB/1 INFO version=([^ ]+) platform=psvita build=([^ ]+) commit=([^ ]+)$'
    $matches = @(& $stringsTool $resolvedElf | Where-Object { $_ -match $infoPattern })
    if ($LASTEXITCODE -ne 0) {
        throw "arm-vita-eabi-strings.exe failed for '$resolvedElf' with exit code $LASTEXITCODE."
    }
    if ($matches.Count -ne 1) {
        throw "Expected exactly one embedded VitaLab INFO identity in '$resolvedElf'; found $($matches.Count)."
    }
    if ($matches[0] -notmatch $infoPattern) {
        throw "Could not parse the embedded VitaLab INFO identity in '$resolvedElf'."
    }

    [pscustomobject]@{
        AgentVersion = $Matches[1]
        BuildId = $Matches[2]
        GitCommit = $Matches[3]
        Info = $matches[0]
    }
}

function Assert-VitaLabIdentityMatchesElf {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Expected,
        [Parameter(Mandatory = $true)]
        [string]$AgentVersion,
        [Parameter(Mandatory = $true)]
        [string]$BuildId,
        [Parameter(Mandatory = $true)]
        [string]$GitCommit
    )

    if ($AgentVersion -ne $Expected.AgentVersion -or
        $BuildId -ne $Expected.BuildId -or
        $GitCommit -ne $Expected.GitCommit) {
        throw "Running agent identity does not match the selected ELF. Agent: version=$AgentVersion build=$BuildId commit=$GitCommit. ELF: version=$($Expected.AgentVersion) build=$($Expected.BuildId) commit=$($Expected.GitCommit)."
    }
}
